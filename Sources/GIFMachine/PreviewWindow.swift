import AppKit
import AVFoundation
import GIFMachineCore
import SwiftUI

// The preview window: the clip playing on a loop, every choice shown in it at once (the speed as the play rate, the trim
// as the loop, a GIF's frame rate and size on the picture), a trim bar, MP4 or GIF, the speed, Smaller for a GIF, and
// Copy. Nothing is made until Copy, except the format and speed the settings ask for, which start at Stop. No control
// locks while a clip is made; changing a choice stops it. Show in Finder and Close sit on the clip's top corners while
// the pointer is over the window (Tim, 2026-11-21, picked "On the clip" from three prototyped layouts).

struct PreviewContent: View {
    @ObservedObject var model: ClipModel
    var resized: (CGSize) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let video = model.videoSize(in: CGSize(width: 296, height: 220))
            PlayerView(model: model)
                .frame(width: video.width, height: video.height)
                .frame(width: 296, height: video.height)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Clip")
                .accessibilityHint(model.pending ? "Drag to drop the copied file, made before these changes" : "Drag to drop the copied file")
                .help(model.pending ? "Drag the clip to drop the copied file, made before these changes" : "Drag the clip to drop the copied file")
                .overlay(alignment: .top) {
                    HStack(spacing: 6) {
                        FloatingButton(symbol: "folder", label: model.pending ? "Show the copied file in Finder" : "Show in Finder",
                                       action: model.showInFinder)
                        if let openEditor = model.onOpenEditor {
                            FloatingButton(symbol: "slider.horizontal.3", label: "Open in Editor", action: openEditor)
                        }
                        Spacer()
                        FloatingButton(symbol: "xmark", label: "Close", action: model.onClose)
                    }
                    .padding(6)
                    .opacity(model.pointerInside || voiceOver ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.pointerInside)
                }
            HStack(spacing: 6) {
                TrimBar(model: model)
                IconButton(symbol: "arrow.uturn.backward", label: "Keep all of it", action: model.resetTrim)
                    .opacity(model.choice.trim == nil ? 0 : 1)
                    .disabled(model.choice.trim == nil)
            }
            HStack(spacing: 6) {
                Segments(name: "Format", options: [(Config.Format.mp4, "MP4"), (.gif, "GIF")], selection: model.choice.format,
                         width: 46, choose: model.choose)
                Spacer(minLength: 4)
                Segments(name: "Speed", options: Config.Speed.allCases.map { ($0, $0.label) }, selection: model.choice.speed,
                         width: 38, choose: model.choose)
            }
            if model.choice.format == .gif {
                HStack(spacing: 6) {
                    Segments(name: "Frame rate", options: Smaller.Frames.allCases.map { ($0, $0 == .native ? "All" : "\($0.rawValue)") },
                             selection: model.choice.smaller.frames, width: 32, choose: model.choose)
                        .help("Fewer frames make a smaller GIF: all of them up to 50 a second, or 30, 20, 15 or 10")
                    Text("fps").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Segments(name: "Size", options: [(true, "Half size")], selection: model.choice.smaller.halfSize, width: 80) { _ in
                        model.toggleHalfSize()
                    }
                    .help("Half the width and height: about a quarter of the size")
                }
            }
            CopyButton(model: model)
            if let sizeSwitch = model.sizeSwitch {
                SizeSwitchButton(label: model.sizeSwitchLabel,
                                 action: sizeSwitch == .smaller ? model.copySmaller : model.copyFullSize)
            }
            if let note = model.note {
                Text(note)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { model.pointerInside = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
    }
}

/// Copy GIF with the clip's length, then Making… with its progress filling the button, then Copied with the file's size
/// once the clipboard holds what's chosen.
struct CopyButton: View {
    @ObservedObject var model: ClipModel
    @State private var hovered = false

    var body: some View {
        let making = model.making != nil
        let quiet = model.isCopied
        Button { model.copy() } label: {
            HStack(spacing: 5) {
                if quiet { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                Text(model.copyLabel).monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(quiet ? Color.secondary : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(quiet ? Color(nsColor: Theme.toolSelection) : Color.accentColor.opacity(making ? 0.55 : 1))
                        if let progress = model.making, progress > 0 {
                            Rectangle().fill(Color.accentColor).frame(width: geometry.size.width * progress)
                        }
                        if hovered, !making, !quiet { Color.white.opacity(0.1) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(model.copyHelp)
        .accessibilityLabel(model.copyLabel)
        .accessibilityValue(model.making.map { "\(Int($0 * 100)) percent" } ?? "")
    }
}

/// The second copy action under Copy: a smaller MP4, or full size again.
struct SizeSwitchButton: View {
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background { if hovered { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: Theme.rowHover)) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

/// A round dark button over the clip, like a screenshot thumbnail's.
struct FloatingButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(hovered ? 0.75 : 0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The recording's length as a bar, the kept part between two handles. Dragging a handle shows the frame under it.
struct TrimBar: View {
    @ObservedObject var model: ClipModel
    /// The shortest part a trim keeps, in seconds.
    private let shortest = 0.2

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(model.duration, 0.001)
            let range = model.shownTrim
            let x = { (time: Double) in CGFloat(time / duration) * width }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: max(12, x(range.upperBound) - x(range.lowerBound)))
                    .offset(x: x(range.lowerBound))
                handle(at: x(range.lowerBound), label: "Start") { location in
                    let start = min(max(0, Double(location / width) * duration), range.upperBound - shortest)
                    model.drag(start...range.upperBound, showing: start)
                }
                handle(at: x(range.upperBound) - 10, label: "End") { location in
                    let end = max(min(duration, Double(location / width) * duration), range.lowerBound + shortest)
                    model.drag(range.lowerBound...end, showing: end)
                }
            }
            .coordinateSpace(.named("trim"))
        }
        .frame(height: 28)
        .help("Drag either end to keep part of the clip")
    }

    private func handle(at x: CGFloat, label: String, moved: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
            .frame(width: 10, height: 28)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 10))
            .contentShape(Rectangle().inset(by: -6))
            .offset(x: x)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                .onChanged { moved($0.location.x) }
                .onEnded { _ in model.endDrag() })
            .accessibilityLabel("Trim \(label.lowercased())")
    }
}

/// A row of choices, the chosen one filled like the bar's tools.
struct Segments<Value: Hashable>: View {
    let name: String
    let options: [(Value, String)]
    let selection: Value
    let width: CGFloat
    let choose: (Value) -> Void
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button { choose(value) } label: {
                    Text(label)
                        .font(.system(size: 13, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(selection == value ? .primary : .secondary)
                        .frame(width: width, height: 28)
                        .contentShape(Rectangle())
                        .background {
                            if selection == value {
                                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Theme.toolSelection))
                            } else if hovered == value {
                                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Theme.rowHover))
                            }
                        }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { inside in
                    if inside { hovered = value } else if hovered == value { hovered = nil }
                }
                .accessibilityLabel("\(label) \(name.lowercased())")
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .background { if hovered { RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Theme.rowHover)) } }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The playing clip. Dragging it drops the clip's file, as it is at the moment the drag starts.
struct PlayerView: NSViewRepresentable {
    let model: ClipModel

    func makeNSView(context: Context) -> ClipView {
        let view = ClipView()
        let layer = AVPlayerLayer(player: model.player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        view.file = { [weak model] in model?.output }
        return view
    }

    func updateNSView(_ view: ClipView, context: Context) {}
}

/// An AppKit drag source: SwiftUI's drag modifier never sees the mouse over a layer-hosting view.
final class ClipView: NSView, NSDraggingSource {
    var file: () -> URL? = { nil }
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let url = file() else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64),
                              contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Floats in the bottom-right corner of the screen without taking focus, so a paste goes where the person was working.
/// It grows upward as rows appear and stays inside the screen.
@MainActor
final class PreviewWindow {
    /// Seconds the window stays after the pointer leaves it, once the clipboard holds what's chosen.
    static let closesAfter: TimeInterval = 6

    let model: ClipModel
    var onClose: () -> Void = {}
    private let panel = GlassPanel(level: .floating)
    private var surface: ResizingGlass?
    private var screen: NSScreen?
    private var size = CGSize(width: 320, height: 400)
    private var deadline = Date()
    private var timer: Timer?

    init(model: ClipModel) {
        self.model = model
        model.onClose = { [weak self] in self?.close() }
    }

    func show(on screen: NSScreen) {
        self.screen = screen
        // Resizing the window inside SwiftUI's layout pass leaves the content laid out for the old size.
        let hosting = FirstClickHostingView(rootView: PreviewContent(model: model) { [weak self] size in
            DispatchQueue.main.async { self?.resize(to: size) }
        })
        hosting.sizingOptions = []
        let surface = ResizingGlass(content: hosting)
        self.surface = surface
        panel.contentView = surface
        resize(to: hosting.fittingSize)
        panel.orderFrontRegardless()
        deadline = Date().addingTimeInterval(Self.closesAfter)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, let screen else { return }
        self.size = size
        let visible = screen.visibleFrame
        let height = min(size.height, visible.height - 40)
        panel.setFrame(CGRect(x: visible.maxX - 20 - size.width, y: visible.minY + 20, width: size.width, height: height), display: false)
        surface?.fit(CGSize(width: size.width, height: height))
    }

    func close() {
        timer?.invalidate()
        timer = nil
        model.stop()
        panel.orderOut(nil)
        onClose()
    }

    /// Reads the pointer's position rather than hover events, which stop arriving when a drag starts in the window.
    /// Choices not yet copied keep it open, so they aren't lost.
    private func tick() {
        if panel.frame.contains(NSEvent.mouseLocation) || model.pending {
            deadline = Date().addingTimeInterval(Self.closesAfter)
        } else if Date() >= deadline {
            close()
        }
    }
}

/// The glass surface of `glassSurface`, for content whose height changes: every layer is sized explicitly, because the
/// glass view doesn't pass autoresizing on to its content reliably.
final class ResizingGlass: NSVisualEffectView {
    private let content: NSView
    private var glass: NSView?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        maskImage = .roundedMask(radius: 16)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            glass.contentView = content
            addSubview(glass)
            self.glass = glass
        } else {
            addSubview(content)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(_ size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        frame = bounds
        glass?.frame = bounds
        content.frame = bounds
        content.needsLayout = true
    }
}
