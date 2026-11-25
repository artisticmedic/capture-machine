import AppKit
import GIFMachineCore
import QuartzCore
import SwiftUI

// The permission guide: a panel attached to System Settings that hands over the app icon to drag into a privacy list,
// and follows each macOS prompt after the drop. It finds System Settings through the window server, so it needs no
// permission of its own. Behaviour measured on macOS 27.2: the drop asks for the password, adds the app switched on,
// then offers Quit & Reopen; the running process gets the grant only after the relaunch.

enum PermissionKind: String {
    case screen, keys

    var anchor: String { self == .screen ? "Privacy_ScreenCapture" : "Privacy_ListenEvent" }
    var list: String { self == .screen ? "Screen & System Audio Recording" : "Input Monitoring" }
    var name: String { self == .screen ? "Screen Recording" : "Input Monitoring" }
    var granted: Bool { self == .screen ? CGPreflightScreenCaptureAccess() : CGPreflightListenEventAccess() }
}

@MainActor
final class GuideModel: ObservableObject {
    enum Phase: String { case drag, dragging, missed, password, quitAlert, reopen, enable, done }

    @Published var phase: Phase { didSet { onPhase?(phase) } }
    @Published var hoveringTile = false
    let kind: PermissionKind
    let reduceMotion: Bool
    var onPhase: ((Phase) -> Void)?

    init(kind: PermissionKind, phase: Phase, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.kind = kind
        self.phase = phase
        self.reduceMotion = reduceMotion
    }

    private var app: String { Paths.appName }

    var step: String {
        switch phase {
        case .drag, .dragging, .missed: "Step 1 of 3"
        case .password, .enable: "Step 2 of 3"
        case .quitAlert, .reopen: "Step 3 of 3"
        case .done: ""
        }
    }

    var title: String {
        switch phase {
        case .drag: "Drag \(app) into the list above"
        case .dragging: "Drop it in the list"
        case .missed: "That missed the list"
        case .password: "Enter your Mac password"
        case .quitAlert: "Choose Quit & Reopen"
        case .reopen: "Reopen \(app) to finish"
        case .enable: "Turn on \(app)"
        case .done: "\(kind.name) is on"
        }
    }

    var detail: String {
        switch phase {
        case .drag: "Next, macOS asks for your password."
        case .dragging: "Let go anywhere over the \(kind.list) list."
        case .missed: "Drag the icon again and let go over the list above."
        case .password: "macOS asks before it adds an app to this list."
        case .quitAlert: "\(app) opens again with \(kind.name) on."
        case .reopen: "\(kind.name) starts working the next time \(app) opens."
        case .enable: "Click the switch next to it in the list."
        case .done: kind == .screen ? "You can close System Settings." : "Keystrokes show in your next recording."
        }
    }

    /// The list already holds the app once the restart alert shows.
    var listed: Bool { [.quitAlert, .reopen, .done].contains(phase) }
}

// MARK: The icon to drag

/// The payload of a drag from Finder: the app bundle's file URL.
private final class BundleWriter: NSObject, NSPasteboardWriting {
    let url: URL
    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .fileURL ? url.absoluteString : [url.path]
    }
}

final class GuideTileView: NSView, NSDraggingSource {
    weak var model: GuideModel?
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    private var downPoint: NSPoint?
    private var tracking: NSTrackingArea?
    private var lifted = false { didSet { needsDisplay = true } }
    var listed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with event: NSEvent) { lifted = true; model?.hoveringTile = true }
    override func mouseExited(with event: NSEvent) { lifted = false; model?.hoveringTile = false }
    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow; NSCursor.closedHand.set() }
    override func mouseUp(with event: NSEvent) { downPoint = nil; NSCursor.openHand.set() }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint, hypot(event.locationInWindow.x - downPoint.x, event.locationInWindow.y - downPoint.y) > 3 else { return }
        self.downPoint = nil
        let item = NSDraggingItem(pasteboardWriter: BundleWriter(url: Bundle.main.bundleURL))
        let size: CGFloat = 64
        let point = convert(event.locationInWindow, from: nil)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        image.unlockFocus()
        item.setDraggingFrame(NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size), contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        model?.phase = .dragging
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let model else { return }
        if model.kind.granted {
            model.phase = model.kind == .screen ? .reopen : .done
            return
        }
        model.phase = operation.isEmpty ? .missed : .password
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = lifted ? 2 : 4
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(lifted ? 0.28 : 0.16)
        shadow.shadowBlurRadius = lifted ? 7 : 3
        shadow.shadowOffset = NSSize(width: 0, height: lifted ? -3 : -1)
        shadow.set()
        icon.draw(in: bounds.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard listed else { return }
        let badge = NSRect(x: bounds.maxX - 22, y: bounds.maxY - 22, width: 20, height: 20)
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: badge.minX + 5.5, y: badge.midY))
        check.line(to: NSPoint(x: badge.minX + 8.6, y: badge.midY + 3.2))
        check.line(to: NSPoint(x: badge.maxX - 5, y: badge.minY + 6))
        check.lineWidth = 2.2
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor.white.setStroke()
        check.stroke()
    }
}

private struct GuideTile: NSViewRepresentable {
    @ObservedObject var model: GuideModel

    func makeNSView(context: Context) -> GuideTileView {
        let view = GuideTileView()
        view.model = model
        return view
    }

    func updateNSView(_ view: GuideTileView, context: Context) {
        view.listed = model.listed
    }
}

// MARK: The panel

/// For a system that adds the app switched off: a switch that turns itself on.
private struct SwitchHint: View {
    let animated: Bool
    @State private var on = false

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.14))
            Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(2)
        }
        .frame(width: 38, height: 22)
        .accessibilityHidden(true)
        .task {
            guard animated else { on = true; return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) { on = true }
                try? await Task.sleep(for: .milliseconds(1500))
                withAnimation(.easeOut(duration: 0.2)) { on = false }
            }
        }
    }
}

struct GuideView: View {
    @ObservedObject var model: GuideModel
    var close: () -> Void
    var reopen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            GuideTile(model: model)
                .frame(width: 60, height: 60)
                .accessibilityLabel("\(Paths.appName) app icon. Drag it into the \(model.kind.list) list.")
            VStack(alignment: .leading, spacing: 2) {
                if !model.step.isEmpty {
                    Text(model.step).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(model.title).font(.system(size: 13, weight: .semibold))
                Text(model.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.phase == .reopen {
                    Button("Reopen \(Paths.appName)", action: reopen)
                        .controlSize(.small)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.18), value: model.phase)
            if model.phase == .enable {
                SwitchHint(animated: !model.reduceMotion)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 30)
        .padding(.vertical, 12)
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(8)
        }
    }
}

/// Popover material in a rounded shape with a pointer on the edge that faces the list. It never takes focus, so System
/// Settings stays the active app while the icon is dragged.
final class GuidePanel: NSPanel {
    static let pointer: CGFloat = 9
    private let effect = NSVisualEffectView()
    private let host: NSHostingView<GuideView>
    private let sizer: NSHostingController<GuideView>
    var pointerEdge: NSRectEdge = .maxY
    var pointerOffset: CGFloat = 60

    init(view: GuideView) {
        host = NSHostingView(rootView: view)
        sizer = NSHostingController(rootView: view)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        contentView = effect
        effect.addSubview(host)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static func pointerSpace(_ edge: NSRectEdge) -> CGSize {
        edge == .maxY || edge == .minY ? CGSize(width: 0, height: pointer) : CGSize(width: pointer, height: 0)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let space = Self.pointerSpace(pointerEdge)
        return ceil(sizer.sizeThatFits(in: CGSize(width: width - space.width, height: 600)).height) + space.height
    }

    func layout(frame: NSRect) {
        setFrame(frame, display: true)
        var body = NSRect(origin: .zero, size: frame.size)
        switch pointerEdge {
        case .maxY: body.size.height -= Self.pointer
        case .minY: body.origin.y += Self.pointer; body.size.height -= Self.pointer
        case .minX: body.origin.x += Self.pointer; body.size.width -= Self.pointer
        default: body.size.width -= Self.pointer
        }
        host.frame = body
        effect.maskImage = Self.mask(size: frame.size, body: body, edge: pointerEdge, offset: pointerOffset)
    }

    private static func mask(size: NSSize, body: NSRect, edge: NSRectEdge, offset: CGFloat) -> NSImage {
        let n = pointer
        return NSImage(size: size, flipped: false) { _ in
            let half: CGFloat = 10
            let tip = NSBezierPath()
            switch edge {
            case .maxY:
                tip.move(to: NSPoint(x: offset - half, y: body.maxY - 1))
                tip.curve(to: NSPoint(x: offset, y: body.maxY + n), controlPoint1: NSPoint(x: offset - half * 0.45, y: body.maxY),
                          controlPoint2: NSPoint(x: offset - 2.5, y: body.maxY + n))
                tip.curve(to: NSPoint(x: offset + half, y: body.maxY - 1), controlPoint1: NSPoint(x: offset + 2.5, y: body.maxY + n),
                          controlPoint2: NSPoint(x: offset + half * 0.45, y: body.maxY))
            case .minX:
                tip.move(to: NSPoint(x: body.minX + 1, y: offset - half))
                tip.curve(to: NSPoint(x: body.minX - n, y: offset), controlPoint1: NSPoint(x: body.minX, y: offset - half * 0.45),
                          controlPoint2: NSPoint(x: body.minX - n, y: offset - 2.5))
                tip.curve(to: NSPoint(x: body.minX + 1, y: offset + half), controlPoint1: NSPoint(x: body.minX - n, y: offset + 2.5),
                          controlPoint2: NSPoint(x: body.minX, y: offset + half * 0.45))
            case .maxX:
                tip.move(to: NSPoint(x: body.maxX - 1, y: offset - half))
                tip.curve(to: NSPoint(x: body.maxX + n, y: offset), controlPoint1: NSPoint(x: body.maxX, y: offset - half * 0.45),
                          controlPoint2: NSPoint(x: body.maxX + n, y: offset - 2.5))
                tip.curve(to: NSPoint(x: body.maxX - 1, y: offset + half), controlPoint1: NSPoint(x: body.maxX + n, y: offset + 2.5),
                          controlPoint2: NSPoint(x: body.maxX, y: offset + half * 0.45))
            default: break
            }
            tip.close()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: body, xRadius: 14, yRadius: 14).fill()
            tip.fill()
            return true
        }
    }
}

// MARK: The hint

/// A ghost of the icon that flies from the panel into the list on a loop, with a closed hand and a ring where it lands.
/// With Reduce Motion, a still dotted arrow along the same path instead.
final class GhostView: NSView {
    private let ghost = CALayer()
    private let hand = CALayer()
    private let ring = CAShapeLayer()
    private let trail = CAShapeLayer()
    var start = CGPoint.zero
    var end = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        ghost.contents = icon.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: NSAffineTransform()])
        ghost.contentsScale = 2
        ghost.bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
        ghost.shadowOpacity = 0.3
        ghost.shadowRadius = 8
        ghost.shadowOffset = CGSize(width: 0, height: -4)
        ghost.opacity = 0
        let cursor = NSCursor.closedHand.image
        hand.contents = cursor.cgImage(forProposedRect: nil, context: nil, hints: nil)
        hand.bounds = CGRect(origin: .zero, size: cursor.size)
        hand.contentsScale = 2
        hand.opacity = 0
        ring.fillColor = nil
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 2.5
        ring.path = CGPath(ellipseIn: CGRect(x: -26, y: -26, width: 52, height: 52), transform: nil)
        ring.opacity = 0
        trail.fillColor = nil
        trail.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        trail.lineWidth = 2
        trail.lineDashPattern = [2, 6]
        trail.lineCap = .round
        trail.opacity = 0
        for sublayer in [trail, ring, ghost, hand] { layer?.addSublayer(sublayer) }
    }

    required init?(coder: NSCoder) { nil }

    /// The curve bows away from the panel: downward-first for a list above, outward-first for one to the side.
    private var control: CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        if abs(dy) > abs(dx) * 0.6 { return CGPoint(x: start.x + dx * 0.1, y: start.y + dy * 0.75) }
        return CGPoint(x: start.x + dx * 0.6, y: start.y + abs(dx) * 0.35)
    }

    private func point(_ t: CGFloat) -> CGPoint {
        let c = control, u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * c.x + t * t * end.x, y: u * u * start.y + 2 * u * t * c.y + t * t * end.y)
    }

    func updateTrail() {
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        let near = point(0.94), angle = atan2(end.y - near.y, end.x - near.x)
        let wing: CGFloat = 9
        path.move(to: CGPoint(x: end.x - wing * cos(angle - 0.5), y: end.y - wing * sin(angle - 0.5)))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - wing * cos(angle + 0.5), y: end.y - wing * sin(angle + 0.5)))
        trail.path = path
    }

    private static func ease(_ x: CGFloat) -> CGFloat { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    private static func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }

    /// One loop at `f` in 0..<1: lift over the first 10%, travel to 58%, drop to 70%, the ring to 82%, then rest.
    func pose(_ f: CGFloat, visible: Bool, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard visible else {
            for sublayer in [ghost, hand, ring, trail] { sublayer.opacity = 0 }
            return
        }
        if reduceMotion {
            ghost.opacity = 0; hand.opacity = 0; ring.opacity = 0
            trail.opacity = 1
            return
        }
        trail.opacity = 0
        let lift = Self.clamp(f / 0.1)
        let travel = Self.ease(Self.clamp((f - 0.1) / 0.48))
        let drop = Self.clamp((f - 0.58) / 0.12)
        let p = point(travel)
        let scale = 1 + 0.08 * lift - 0.26 * drop
        ghost.position = p
        ghost.transform = CATransform3DMakeScale(scale, scale, 1)
        ghost.opacity = Float(f < 0.7 ? 0.92 * lift * (1 - drop) : 0)
        hand.position = CGPoint(x: p.x + 14, y: p.y - 16)
        hand.opacity = ghost.opacity
        let r = Self.clamp((f - 0.58) / 0.24)
        ring.position = end
        ring.transform = CATransform3DMakeScale(0.5 + r, 0.5 + r, 1)
        ring.opacity = Float(r > 0 && r < 1 ? 0.85 * (1 - r) : 0)
    }
}

/// Spans System Settings and the panel; clicks go through it.
final class GhostWindow: NSPanel {
    let view = GhostView(frame: .zero)

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = view
    }
}

// MARK: Finding System Settings

struct SystemSettingsWindow {
    var frame: NSRect
    var screen: NSScreen
    /// A small System Settings window over the main one: the password prompt or the restart alert.
    var dialog: NSSize?

    /// Bounds come from the window server without Screen Recording; titles would need it, so windows are told apart by
    /// size. The main window is the largest; a prompt is a second one, centred over it.
    static func find() -> SystemSettingsWindow? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first(where: { $0.activationPolicy != .prohibited })?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame.maxY
        else { return nil }
        let windows: [NSRect] = list.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return NSRect(x: cg.minX, y: primary - cg.maxY, width: cg.width, height: cg.height)
        }
        guard let frame = windows.filter({ $0.width > 320 && $0.height > 240 }).max(by: { $0.width * $0.height < $1.width * $1.height })
        else { return nil }
        let dialog = windows.first { other in
            (180...440).contains(other.width) && (120...560).contains(other.height) && frame.contains(NSPoint(x: other.midX, y: other.midY))
        }?.size
        let screen = NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(frame), ib = b.frame.intersection(frame)
            return ia.width * ia.height < ib.width * ib.height
        } ?? NSScreen.screens[0]
        return SystemSettingsWindow(frame: frame, screen: screen, dialog: dialog)
    }
}

// MARK: The guide

@MainActor
final class PermissionGuide: NSObject {
    static let shared = PermissionGuide()

    /// Set while a guide is open, so the process macOS relaunches after the grant can say it worked.
    private static let pendingKey = "permissionGuidePending"
    /// System Settings on macOS 27.2: the sidebar's width, and where the list starts below the window's top edge.
    private static let sidebar: CGFloat = 230
    private static let listTop: CGFloat = 180

    private enum Placement: String { case below, right, left, inside }

    private var model: GuideModel?
    private var panel: GuidePanel?
    private var ghost: GhostWindow?
    private var link: CADisplayLink?
    private var poller: Timer?
    private var settings: SystemSettingsWindow?
    private var opened = Date()
    private var lastSeen = Date()
    private var everSeen = false
    private var phaseSince = Date()
    private var sawDialog = false
    private var cycleStart = CACurrentMediaTime()
    private var pausedUntil: CFTimeInterval = 0
    private var lastLayout = ""
    private var shown: CGFloat = 0
    private var closing = false

    var isOpen: Bool { model != nil }

    /// Opens System Settings at the permission's list and attaches the guide to it.
    func open(_ kind: PermissionKind) {
        if let model, model.kind == kind, model.phase != .done {
            openSettings(kind)
            return
        }
        close()
        UserDefaults.standard.set(kind.rawValue, forKey: Self.pendingKey)
        openSettings(kind)
        start(GuideModel(kind: kind, phase: kind.granted ? .done : .drag))
    }

    /// At launch: the guide was open when the app quit. When the grant has arrived, which on macOS 27.2 takes Quit &
    /// Reopen, says so over System Settings for a moment. Returns whether it did.
    @discardableResult
    func resumeAfterRelaunch() -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: Self.pendingKey) else { return false }
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        guard let kind = PermissionKind(rawValue: raw), kind.granted else { return false }
        start(GuideModel(kind: kind, phase: .done))
        return true
    }

    func close() {
        link?.invalidate()
        link = nil
        poller?.invalidate()
        poller = nil
        panel?.orderOut(nil)
        ghost?.orderOut(nil)
        panel = nil
        ghost = nil
        if model != nil {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            StatusFile.update { $0.permissionGuide = nil }
        }
        model = nil
        settings = nil
    }

    private func openSettings(_ kind: PermissionKind) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func start(_ model: GuideModel) {
        self.model = model
        let view = GuideView(model: model, close: { [weak self] in self?.close() }, reopen: { [weak self] in self?.reopen() })
        let panel = GuidePanel(view: view)
        let ghost = GhostWindow()
        panel.alphaValue = 0
        ghost.alphaValue = 0
        self.panel = panel
        self.ghost = ghost
        opened = Date()
        everSeen = false
        sawDialog = false
        closing = false
        shown = 0
        lastLayout = ""
        phaseSince = Date()
        cycleStart = CACurrentMediaTime()
        model.onPhase = { [weak self] phase in self?.entered(phase) }
        entered(model.phase)
        let link = (NSScreen.main ?? NSScreen.screens[0]).displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        poller = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func entered(_ phase: GuideModel.Phase) {
        lastLayout = ""
        phaseSince = Date()
        cycleStart = CACurrentMediaTime()
        if phase == .missed { pausedUntil = CACurrentMediaTime() + 0.8 }
        StatusFile.update { $0.permissionGuide = "\(model?.kind.rawValue ?? "") \(phase.rawValue)" }
        guard phase == .done else { return }
        // Long enough to read, then the panel fades out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            closing = true
        }
    }

    /// After the drop: the password prompt, about 348 points tall, then the restart alert, about 237. With no prompt at
    /// all, the system added the app switched off.
    private func follow(_ dialog: NSSize?) {
        guard let model else { return }
        switch (model.phase, dialog) {
        case (.password, let size?), (.enable, let size?):
            sawDialog = true
            if size.height < 290 { model.phase = .quitAlert }
        case (.password, nil) where !sawDialog && Date().timeIntervalSince(phaseSince) > 4:
            model.phase = .enable
        case (.quitAlert, nil):
            model.phase = model.kind == .keys && model.kind.granted ? .done : .reopen
        default:
            break
        }
    }

    private func poll() {
        guard let model, model.kind.granted, model.phase != .done, model.phase != .reopen, model.phase != .quitAlert else { return }
        model.phase = model.kind == .screen ? .reopen : .done
    }

    /// The Later path: the same relaunch the welcome window's Reopen does.
    private func reopen() {
        link?.invalidate()
        ScreenPermission.relaunch()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let model, let panel, let ghost else { return }
        let now = Date()
        if let found = SystemSettingsWindow.find() {
            settings = found
            lastSeen = now
            everSeen = true
        } else if everSeen ? now.timeIntervalSince(lastSeen) > 0.6 : now.timeIntervalSince(opened) > 8 {
            return close()
        }
        guard let settings else { return }
        if model.phase != .done { follow(settings.dialog) }
        place(settings, panel: panel, ghost: ghost)
        // Shown while System Settings is in front, and while the app is in front with no window of its own: a click on
        // the panel's button can bring the app forward.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let visible = front == "com.apple.systempreferences" || (front == Bundle.main.bundleIdentifier && NSApp.keyWindow == nil)
        let target: CGFloat = closing ? 0 : visible ? 1 : 0
        shown += (target - shown) * 0.25
        if abs(target - shown) < 0.01 { shown = target }
        if closing, shown == 0 { return close() }
        panel.alphaValue = shown
        ghost.alphaValue = shown
        if shown > 0, !panel.isVisible {
            panel.orderFrontRegardless()
            ghost.orderFrontRegardless()
        }
        animateGhost(model: model, ghost: ghost)
    }

    private func animateGhost(model: GuideModel, ghost: GhostWindow) {
        let now = CACurrentMediaTime()
        let cycle: CFTimeInterval = 3.2
        let hint = model.phase == .drag || model.phase == .missed
        let visible = hint && !model.hoveringTile && now >= pausedUntil
        // Paused, the loop waits at its resting part, so it starts again from the lift.
        if !visible { cycleStart = now - cycle * 0.72 }
        let f = CGFloat((now - cycleStart).truncatingRemainder(dividingBy: cycle) / cycle)
        ghost.view.pose(f, visible: hint && (visible || model.reduceMotion), reduceMotion: model.reduceMotion)
    }

    /// Below the window when it fits, otherwise beside it, otherwise over its lower edge. The pointer aims at the top of
    /// the list in the content column, which holds however many apps the list has.
    private func place(_ settings: SystemSettingsWindow, panel: GuidePanel, ghost: GhostWindow) {
        let visible = settings.screen.visibleFrame
        let gap: CGFloat = 8
        let content = NSRect(x: settings.frame.minX + Self.sidebar, y: settings.frame.minY,
                             width: settings.frame.width - Self.sidebar, height: settings.frame.height)
        let target = CGPoint(x: content.midX, y: settings.frame.maxY - Self.listTop)
        let belowWidth = min(max(content.width - 32, 340), 480)
        let sideWidth: CGFloat = 340
        panel.pointerEdge = .maxY
        let belowHeight = panel.height(forWidth: belowWidth)
        let placement: Placement = settings.frame.minY - gap - belowHeight >= visible.minY ? .below
            : settings.frame.maxX + gap + sideWidth <= visible.maxX ? .right
            : settings.frame.minX - gap - sideWidth >= visible.minX ? .left
            : .inside
        let frame: NSRect
        switch placement {
        case .below, .inside:
            let x = min(max(content.midX - belowWidth / 2, visible.minX + 8), visible.maxX - belowWidth - 8)
            let y = placement == .below ? settings.frame.minY - gap - belowHeight : settings.frame.minY + 16
            frame = NSRect(x: x, y: y, width: belowWidth, height: belowHeight)
            panel.pointerOffset = min(max(target.x - x, 28), belowWidth - 28)
        case .right, .left:
            panel.pointerEdge = placement == .right ? .minX : .maxX
            let height = panel.height(forWidth: sideWidth)
            let x = placement == .right ? settings.frame.maxX + gap : settings.frame.minX - gap - sideWidth
            let y = min(max(target.y - height / 2, visible.minY + 8), visible.maxY - height - 8)
            frame = NSRect(x: x, y: y, width: sideWidth, height: height)
            panel.pointerOffset = min(max(target.y - y, 24), height - 24)
        }
        let layout = "\(placement.rawValue) \(frame) \(model?.phase.rawValue ?? "")"
        if layout != lastLayout || panel.frame != frame {
            panel.layout(frame: frame)
            lastLayout = layout
        }
        let span = settings.frame.union(frame).insetBy(dx: -40, dy: -40)
        if ghost.frame != span { ghost.setFrame(span, display: false) }
        ghost.view.frame = NSRect(origin: .zero, size: span.size)
        let tile: CGPoint
        switch panel.pointerEdge {
        case .maxY: tile = CGPoint(x: frame.minX + 44, y: frame.minY + (frame.height - GuidePanel.pointer) / 2)
        case .minX: tile = CGPoint(x: frame.minX + GuidePanel.pointer + 44, y: frame.midY)
        default: tile = CGPoint(x: frame.minX + 44, y: frame.midY)
        }
        let start = CGPoint(x: tile.x - span.minX, y: tile.y - span.minY)
        let end = CGPoint(x: target.x - span.minX, y: target.y - span.minY)
        if start != ghost.view.start || end != ghost.view.end {
            ghost.view.start = start
            ghost.view.end = end
            ghost.view.updateTrail()
        }
        panel.order(.above, relativeTo: 0)
        ghost.order(.above, relativeTo: panel.windowNumber)
    }
}
