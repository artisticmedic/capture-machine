import AppKit
import GIFMachineCore

/// A red dashed line around what is being recorded, placed by `Outline`. Show it before the recording starts, and
/// pass its window number to the recorder, which leaves it out of the clip.
@MainActor
final class RecordingOutline {
    static let lineWidth: CGFloat = 2
    private var window: NSWindow?
    var windowNumber: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

    /// `rect` is in the screen's own points with a bottom-left origin, as `Capture` gives it.
    func show(_ rect: CGRect, on screen: NSScreen) {
        hide()
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.setFrame(screen.frame, display: false)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        window.contentView = OutlineView(path: Outline.path(around: rect, in: bounds, lineWidth: Self.lineWidth))
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class OutlineView: NSView {
    private let path: CGRect

    init(path: CGRect) {
        self.path = path
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let line = NSBezierPath(rect: path)
        line.lineWidth = RecordingOutline.lineWidth
        // A faint dark line under the dashes keeps them visible on red and on white.
        NSColor.black.withAlphaComponent(0.25).setStroke()
        line.stroke()
        line.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        line.stroke()
    }
}
