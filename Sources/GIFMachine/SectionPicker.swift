import AppKit
import GIFMachineCore

// The area picker: a dimmed overlay on one screen. Drag for a section, point at a window, or the whole screen.
// Each toolbar style sets how it commits. A dragged section snaps to window edges, the screen's edges and the menu bar
// within 8 points (hold Command to place it freely). The last section on each screen is remembered: the bottom bar
// starts with it selected, the other styles outline it and record it on Return. The arrow keys move a selection or
// the remembered section a point at a time, ten with Shift; with Option they resize it.

struct PickerStyle {
    /// Releasing a drag or clicking a window starts the recording. Off: the choice stays on screen until Record.
    var commitsOnRelease: Bool
    /// A click without a drag in Section records the full screen.
    var clickMeansFullScreen: Bool
    /// The readout and key hints follow the pointer.
    var cursorChip: Bool
    var hint: (Tool) -> String?
}

private final class PickerWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .overlay
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The highlighted area is fully transparent, and macOS passes clicks on transparent pixels to the window below.
        ignoresMouseEvents = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class SectionPicker {
    private let window: PickerWindow
    let view: PickerView

    init(screen: NSScreen, tool: Tool, style: PickerStyle) {
        window = PickerWindow(screen: screen)
        view = PickerView(screen: screen, style: style)
        view.tool = tool
        window.contentView = view
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.updateCursor()
    }

    func close() {
        window.orderOut(nil)
        NSCursor.arrow.set()
    }
}

final class PickerView: NSView {
    let screen: NSScreen
    let style: PickerStyle
    var tool: Tool = .section {
        didSet {
            guard tool != oldValue else { return }
            dragRect = nil
            if !style.commitsOnRelease { setSelection(tool == .fullScreen ? fullScreenCapture() : nil) }
            updateCursor()
            needsDisplay = true
        }
    }
    var onCommit: ((Capture) -> Void)?
    var onSelection: ((Capture?) -> Void)?
    /// The menu bar icon's frame in this view. The overlay covers the icon, so a click there cancels instead.
    var cancelZone: CGRect?
    var onCancel: (() -> Void)?
    private(set) var selection: Capture?

    private let windows: [WindowInfo]
    private var anchor: CGPoint?
    private var dragRect: CGRect?
    private var hovered: WindowInfo?
    private var pointer: CGPoint?
    /// The last section recorded on this screen, in this view's coordinates.
    private(set) var remembered: CGRect?
    /// Edges a section can snap to, in this view's coordinates.
    private let snapXs: [CGFloat]
    private let snapYs: [CGFloat]
    /// The dragged section's edges that sit on a snap line, drawn heavier.
    private var snappedX: Set<CGFloat> = []
    private var snappedY: Set<CGFloat> = []
    static let snapDistance: CGFloat = 8

    init(screen: NSScreen, style: PickerStyle) {
        self.screen = screen
        self.style = style
        let origin = screen.frame.origin
        windows = WindowList.onScreen().compactMap { info in
            let local = info.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            let clipped = local.intersection(CGRect(origin: .zero, size: screen.frame.size))
            return clipped.width >= 40 && clipped.height >= 40 ? WindowInfo(frame: clipped.integral, app: info.app) : nil
        }
        let visible = screen.visibleFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        snapXs = [0, screen.frame.width, visible.minX, visible.maxX] + windows.flatMap { [$0.frame.minX, $0.frame.maxX] }
        snapYs = [0, screen.frame.height, visible.minY, visible.maxY] + windows.flatMap { [$0.frame.minY, $0.frame.maxY] }
        remembered = LastSection.load(for: screen)
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
        pointer = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateCursor() {
        (tool == .section ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let location = window.mouseLocationOutsideOfEventStream
        pointer = convert(location, from: nil)
        hovered = windowAt(pointer!)
        if !style.commitsOnRelease, tool == .fullScreen { setSelection(fullScreenCapture()) }
        if !style.commitsOnRelease, tool == .section, let remembered { setSelection(sectionCapture(remembered)) }
    }

    // MARK: Input

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if tool == .window { hovered = windowAt(pointer!) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let cancelZone, cancelZone.contains(point) {
            anchor = nil
            onCancel?()
            return
        }
        switch tool {
        case .section:
            anchor = snapped(point, free: event.modifierFlags.contains(.command))
            dragRect = nil
        case .window:
            guard let window = windowAt(point) else { return }
            let capture = Capture(screen: screen, rect: window.frame, label: "\(window.app) · \(Readout.size(screen, window.frame.size))")
            if style.commitsOnRelease { onCommit?(capture) } else { setSelection(capture) }
        case .fullScreen:
            if style.commitsOnRelease { onCommit?(fullScreenCapture()) }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool == .section, let anchor else { return }
        let point = snapped(convert(event.locationInWindow, from: nil), free: event.modifierFlags.contains(.command))
        pointer = point
        dragRect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                          width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).integral
        if let dragRect {
            snappedX = Set([dragRect.minX, dragRect.maxX].filter { edge in snapXs.contains { abs($0 - edge) < 0.5 } })
            snappedY = Set([dragRect.minY, dragRect.maxY].filter { edge in snapYs.contains { abs($0 - edge) < 0.5 } })
        }
        needsDisplay = true
    }

    /// The point moved onto the nearest snap line within 8 points, across and down separately.
    private func snapped(_ point: CGPoint, free: Bool) -> CGPoint {
        guard !free else { return point }
        func snap(_ value: CGFloat, _ lines: [CGFloat]) -> CGFloat {
            guard let line = lines.min(by: { abs($0 - value) < abs($1 - value) }), abs(line - value) <= Self.snapDistance else { return value }
            return line
        }
        return CGPoint(x: snap(point.x, snapXs), y: snap(point.y, snapYs))
    }

    override func keyDown(with event: NSEvent) {
        if [KeyCode.returnKey, KeyCode.keypadEnter].contains(event.keyCode), style.commitsOnRelease, tool == .section, commitRemembered() { return }
        let moves: [UInt16: CGPoint] = [KeyCode.left: CGPoint(x: -1, y: 0), KeyCode.right: CGPoint(x: 1, y: 0),
                                        KeyCode.up: CGPoint(x: 0, y: 1), KeyCode.down: CGPoint(x: 0, y: -1)]
        guard tool == .section, let move = moves[event.keyCode],
              let rect = style.commitsOnRelease ? remembered : selection?.rect else {
            super.keyDown(with: event)
            return
        }
        nudge(rect, by: move, step: event.modifierFlags.contains(.shift) ? 10 : 1, resizing: event.modifierFlags.contains(.option))
    }

    /// Moves the section, kept on the screen, or with `resizing` moves its right and top edges.
    private func nudge(_ rect: CGRect, by move: CGPoint, step: CGFloat, resizing: Bool) {
        var next = rect
        if resizing {
            next.size.width = max(8, min(bounds.width - next.minX, next.width + move.x * step))
            next.size.height = max(8, min(bounds.height - next.minY, next.height + move.y * step))
        } else {
            next.origin.x = min(max(0, next.minX + move.x * step), bounds.width - next.width)
            next.origin.y = min(max(0, next.minY + move.y * step), bounds.height - next.height)
        }
        LastSection.save(next, for: screen)
        if style.commitsOnRelease { remembered = next } else { setSelection(sectionCapture(next)) }
        needsDisplay = true
    }

    /// Records the remembered section, when there is one.
    @discardableResult
    func commitRemembered() -> Bool {
        guard let remembered else { return false }
        onCommit?(sectionCapture(remembered))
        return true
    }

    private func sectionCapture(_ rect: CGRect) -> Capture {
        Capture(screen: screen, rect: rect, label: Readout.size(screen, rect.size))
    }

    override func mouseUp(with event: NSEvent) {
        guard tool == .section, anchor != nil else { return }
        anchor = nil
        snappedX = []
        snappedY = []
        if let rect = dragRect, rect.width >= 8, rect.height >= 8 {
            let capture = sectionCapture(rect)
            LastSection.save(rect, for: screen)
            remembered = rect
            dragRect = nil
            if style.commitsOnRelease { onCommit?(capture) } else { setSelection(capture) }
        } else {
            dragRect = nil
            if style.clickMeansFullScreen { onCommit?(fullScreenCapture()) }
        }
        needsDisplay = true
    }

    func fullScreenCapture() -> Capture {
        Capture(screen: screen, rect: bounds, label: "Full screen · \(Readout.size(screen, bounds.size))", isFullScreen: true)
    }

    private func setSelection(_ capture: Capture?) {
        selection = capture
        onSelection?(capture)
        needsDisplay = true
    }

    private func windowAt(_ point: CGPoint) -> WindowInfo? {
        windows.first { $0.frame.contains(point) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let hole: CGRect?
        var label: String?
        switch tool {
        case .section:
            if let dragRect {
                hole = dragRect
                label = Readout.size(screen, dragRect.size)
            } else if let selection {
                hole = selection.rect
                label = selection.label
            } else {
                hole = nil
            }
        case .window:
            if !style.commitsOnRelease, let selection {
                hole = selection.rect
                label = selection.label
            } else if let hovered {
                hole = hovered.frame
                label = "\(hovered.app) · \(Readout.size(screen, hovered.frame.size))"
            } else {
                hole = nil
            }
        case .fullScreen:
            hole = bounds
            label = fullScreenCapture().label
        }

        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let hole {
            NSColor.clear.setFill()
            hole.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: hole == bounds ? bounds.insetBy(dx: 1.5, dy: 1.5) : hole.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = hole == bounds ? 3 : 1
            border.stroke()
        }
        if let dragRect, !(snappedX.isEmpty && snappedY.isEmpty) {
            NSColor.white.setStroke()
            for x in snappedX {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: x, y: dragRect.minY))
                line.line(to: CGPoint(x: x, y: dragRect.maxY))
                line.lineWidth = 3
                line.stroke()
            }
            for y in snappedY {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: dragRect.minX, y: y))
                line.line(to: CGPoint(x: dragRect.maxX, y: y))
                line.lineWidth = 3
                line.stroke()
            }
        }
        if tool == .section, style.commitsOnRelease, dragRect == nil, let remembered {
            NSColor.white.withAlphaComponent(0.75).setStroke()
            let outline = NSBezierPath(rect: remembered.insetBy(dx: -0.5, dy: -0.5))
            outline.lineWidth = 1
            outline.setLineDash([6, 4], count: 2, phase: 0)
            outline.stroke()
            if !style.cursorChip {
                drawPill(["Last section · \(Readout.size(screen, remembered.size))", "Return records it · arrows move it"],
                         at: CGPoint(x: remembered.minX, y: remembered.minY - 46), in: bounds)
            }
        }
        if tool == .window, !style.commitsOnRelease, let hovered, hovered.frame != selection?.rect {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let outline = NSBezierPath(rect: hovered.frame.insetBy(dx: -0.5, dy: -0.5))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.stroke()
        }

        if style.cursorChip {
            drawChip(label: label)
        } else {
            if let hole, let label {
                if hole == bounds {
                    drawPill([label], at: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds, centered: true)
                } else {
                    drawPill([label], at: CGPoint(x: hole.minX, y: hole.minY - 30), in: bounds)
                }
            }
            if let hint = style.hint(tool), dragRect == nil {
                drawPill([hint], at: CGPoint(x: bounds.midX, y: bounds.maxY - 120), in: bounds, centered: true)
            }
        }
    }

    private func drawChip(label: String?) {
        guard let pointer else { return }
        var lines: [String]
        switch tool {
        case .section:
            lines = dragRect != nil ? [label ?? ""] : ["Drag a section", "Click: full screen · Space: window"]
                + (remembered == nil ? [] : ["Return: last section"])
        case .window:
            lines = hovered.map { ["\($0.app) · \(Readout.size(screen, $0.frame.size))", "Click to record · Space: section"] }
                ?? ["Point at a window", "Space: section"]
        case .fullScreen:
            lines = [label ?? ""]
        }
        drawPill(lines, at: CGPoint(x: pointer.x + 18, y: pointer.y - 26 - CGFloat(lines.count - 1) * 16), in: bounds)
    }
}

/// The last section recorded on each screen, kept across launches: the screen's display number and size, and the
/// section in points from its bottom-left corner.
enum LastSection {
    private static let key = "lastSections"

    private static func id(_ screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "0"
        return "\(number) \(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    static func load(for screen: NSScreen) -> CGRect? {
        guard let text = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id(screen)] else { return nil }
        let rect = NSRectFromString(text)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        return rect.width >= 8 && rect.height >= 8 && bounds.contains(rect) ? rect : nil
    }

    static func save(_ rect: CGRect, for screen: NSScreen) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[id(screen)] = NSStringFromRect(rect)
        UserDefaults.standard.set(all, forKey: key)
    }
}
