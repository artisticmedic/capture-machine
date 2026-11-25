import AppKit
import GIFMachineCore
import SwiftUI

enum Tool: Int, CaseIterable {
    case window, section, fullScreen

    var title: String { ["Window", "Section", "Full screen"][rawValue] }
    var symbol: String { ["macwindow", "rectangle.dashed", "display"][rawValue] }
    var key: String { ["W", "S", "F"][rawValue] }
}

/// What the person chose to record. `rect` is in the screen's own points with a bottom-left origin.
struct Capture {
    let screen: NSScreen
    let rect: CGRect
    let label: String
    var isFullScreen = false
}

enum KeyCode {
    static let escape: UInt16 = 53, returnKey: UInt16 = 36, keypadEnter: UInt16 = 76, tab: UInt16 = 48, space: UInt16 = 49
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
}

/// The pixel size and frame rate a recording of `size` points would have, as the picker and bar show it.
enum Readout {
    static func fps(_ screen: NSScreen, _ size: CGSize) -> Int {
        let scale = screen.backingScaleFactor
        return FrameRate.forRecording(displayMaximum: screen.maximumFramesPerSecond,
                                      pixelWidth: Int(size.width * scale), pixelHeight: Int(size.height * scale))
    }

    static func size(_ screen: NSScreen, _ size: CGSize) -> String {
        let scale = screen.backingScaleFactor
        return "\(Int(size.width * scale)) × \(Int(size.height * scale)) · \(fps(screen, size)) fps"
    }
}

struct WindowInfo {
    let frame: CGRect
    let app: String
}

enum WindowList {
    /// On-screen app windows, front to back, in AppKit global coordinates. Window titles need Screen Recording
    /// permission, so windows are named by their app.
    static func onScreen() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = getpid()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  cg.width >= 40, cg.height >= 40
            else { return nil }
            return WindowInfo(frame: CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height),
                              app: info[kCGWindowOwnerName as String] as? String ?? "Window")
        }
    }
}

enum Theme {
    static let rowSelection = NSColor.labelColor.withAlphaComponent(0.09)
    static let rowHover = NSColor.labelColor.withAlphaComponent(0.05)
    static let toolSelection = NSColor.labelColor.withAlphaComponent(0.13)
    static let pillInk = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.045, alpha: 0.9)
}

func pointerScreen() -> NSScreen {
    NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

extension NSImage {
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Takes the click that brings its window forward, so a panel that never becomes key still answers the first click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The design language's glass surface, from Shortercat's MenuBarPanel: system glass on macOS 26 and later,
/// the popover material before that, 16 pt corners.
@MainActor
func glassSurface<Content: View>(_ content: Content) -> NSView {
    let hosting = FirstClickHostingView(rootView: content)
    let size = hosting.fittingSize
    let bounds = NSRect(origin: .zero, size: size)
    hosting.frame = bounds
    hosting.autoresizingMask = [.width, .height]
    let surface = NSVisualEffectView(frame: bounds)
    surface.material = .popover
    surface.blendingMode = .behindWindow
    surface.state = .active
    surface.maskImage = .roundedMask(radius: 16)
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView(frame: bounds)
        glass.style = .regular
        glass.cornerRadius = 16
        glass.contentView = hosting
        glass.autoresizingMask = [.width, .height]
        surface.addSubview(glass)
    } else {
        surface.addSubview(hosting)
    }
    return surface
}

final class GlassPanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension NSWindow.Level {
    static let overlay = NSWindow.Level.screenSaver
    static let overOverlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let harness = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
}

/// A dark label pill, as the spike's picker draws its size readout.
func drawPill(_ lines: [String], at point: CGPoint, in bounds: CGRect, centered: Bool = false) {
    let primary: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
    let secondary: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.7)]
    let strings = lines.enumerated().map { NSAttributedString(string: $0.element, attributes: $0.offset == 0 ? primary : secondary) }
    let width = strings.map { $0.size().width }.max() ?? 0
    let lineHeight: CGFloat = 16
    let height = CGFloat(strings.count) * lineHeight
    var origin = CGPoint(x: centered ? point.x - width / 2 : point.x, y: point.y)
    origin.x = min(max(origin.x, bounds.minX + 12), bounds.maxX - width - 12)
    origin.y = min(max(origin.y, bounds.minY + 10), bounds.maxY - height - 10)
    let pill = CGRect(origin: origin, size: CGSize(width: width, height: height)).insetBy(dx: -9, dy: -5)
    Theme.pillInk.setFill()
    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
    for (index, string) in strings.enumerated() {
        string.draw(at: CGPoint(x: origin.x, y: origin.y + height - CGFloat(index + 1) * lineHeight + 1))
    }
}
