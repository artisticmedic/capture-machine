import AppKit
import AVFoundation
import GIFMachineCore
import SwiftUI
import UniformTypeIdentifiers

// The full editor: the preview window's choices with room to work. A large player, a timeline of frames with trim
// handles and a playhead, and a sidebar with the format, the speed, all three Smaller levers with the size estimate, and
// Copy and Save As. It stays open until closed. Keys: Space plays and pauses, the arrows step a frame, I and O trim to
// the playhead, Return copies, Command-S saves as.

struct EditorContent: View {
    @ObservedObject var model: ClipModel
    let saveAs: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                GeometryReader { geometry in
                    let video = model.videoSize(in: geometry.size)
                    PlayerView(model: model)
                        .frame(width: video.width, height: video.height)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityLabel("Clip")
                        .help("Drag the clip to drop the copied file")
                }
                TransportRow(model: model, playhead: model.playhead)
                EditorTimeline(model: model, playhead: model.playhead)
            }
            .padding(20)
            Divider()
            EditorSidebar(model: model, saveAs: saveAs)
                .frame(width: 300)
        }
        .background(Surface.page)
        .focusEffectDisabled()
    }
}

/// A button title with its key beside it, drawn as a key: Trim Start [I].
private struct ShortcutLabel: View {
    let title: String
    let key: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            KeyHint(key: key)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// Play and pause, where the playhead is, and the buttons that trim to it.
struct TransportRow: View {
    @ObservedObject var model: ClipModel
    @ObservedObject var playhead: Playhead

    var body: some View {
        HStack(spacing: 8) {
            IconButton(symbol: playhead.playing ? "pause.fill" : "play.fill", label: playhead.playing ? "Pause" : "Play",
                       action: model.togglePlay)
            Text("\(Self.clock(playhead.time)) / \(Self.clock(model.duration))")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { model.trimStart() } label: { ShortcutLabel(title: "Trim Start", key: "I") }
                .buttonStyle(PillButtonStyle())
                .help("Trim the start to the playhead (I)")
            Button { model.trimEnd() } label: { ShortcutLabel(title: "Trim End", key: "O") }
                .buttonStyle(PillButtonStyle())
                .help("Trim the end to the playhead (O)")
            IconButton(symbol: "arrow.uturn.backward", label: "Keep all of it", action: model.resetTrim)
                .opacity(model.choice.trim == nil ? 0 : 1)
                .disabled(model.choice.trim == nil)
        }
    }

    /// Minutes, seconds and tenths: 0:04.2.
    static func clock(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

/// The recording as a strip of frames. The kept part sits between two handles, the rest is dimmed; dragging anywhere
/// else moves the playhead.
struct EditorTimeline: View {
    @ObservedObject var model: ClipModel
    @ObservedObject var playhead: Playhead
    @State private var thumbnails: [CGImage] = []
    private static let count = 14
    private let height: CGFloat = 56
    private let shortest = 0.2

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let duration = max(model.duration, 0.001)
                let range = model.shownTrim
                let x = { (time: Double) in CGFloat(time / duration) * width }
                ZStack(alignment: .topLeading) {
                    filmstrip(width: width)
                    Rectangle().fill(Color.black.opacity(0.5))
                        .frame(width: max(0, x(range.lowerBound)), height: height)
                    Rectangle().fill(Color.black.opacity(0.5))
                        .frame(width: max(0, width - x(range.upperBound)), height: height)
                        .offset(x: x(range.upperBound))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .frame(width: max(28, x(range.upperBound) - x(range.lowerBound)), height: height)
                        .offset(x: x(range.lowerBound))
                        .allowsHitTesting(false)
                    Rectangle().fill(Color.white)
                        .frame(width: 2, height: height + 10)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .offset(x: x(playhead.time) - 1, y: -5)
                        .allowsHitTesting(false)
                    handle(at: x(range.lowerBound), label: "Start", chevron: "chevron.compact.left") { location in
                        let start = min(max(0, Double(location / width) * duration), range.upperBound - shortest)
                        model.drag(start...range.upperBound, showing: start)
                    }
                    handle(at: x(range.upperBound) - 14, label: "End", chevron: "chevron.compact.right") { location in
                        let end = max(min(duration, Double(location / width) * duration), range.lowerBound + shortest)
                        model.drag(range.lowerBound...end, showing: end)
                    }
                }
                .frame(height: height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { model.scrub(to: Double($0.location.x / width) * duration) }
                    .onEnded { _ in model.endScrub() })
                .coordinateSpace(.named("timeline"))
            }
            .frame(height: height)
            HStack {
                Text(TransportRow.clock(model.shownTrim.lowerBound))
                Spacer()
                Text(model.choice.speed == .normal ? model.length : "\(model.length) at \(model.choice.speed.label)")
                Spacer()
                Text(TransportRow.clock(model.shownTrim.upperBound))
            }
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .task(id: model.duration) { await loadThumbnails() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(Self.count), height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func handle(at x: CGFloat, label: String, chevron: String, moved: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.accentColor)
            .frame(width: 14, height: height)
            .overlay(Image(systemName: chevron).font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
            .contentShape(Rectangle().inset(by: -6))
            .offset(x: x)
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { moved($0.location.x) }
                .onEnded { _ in model.endDrag() })
            .accessibilityLabel("Trim \(label.lowercased())")
            .help("Drag to trim the \(label.lowercased())")
    }

    /// Frames spread evenly across the recording, a few hundred pixels wide.
    private func loadThumbnails() async {
        guard model.plays, model.duration > 0, thumbnails.isEmpty else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: model.source))
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let times = (0..<Self.count).map { CMTime(seconds: model.duration * (Double($0) + 0.5) / Double(Self.count), preferredTimescale: 600) }
        var images: [CGImage] = []
        for time in times {
            guard let image = try? await generator.image(at: time).image else { continue }
            images.append(image)
        }
        thumbnails = images
    }
}

struct EditorSidebar: View {
    @ObservedObject var model: ClipModel
    let saveAs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("Format") {
                Segments(name: "Format", options: [(Config.Format.mp4, "MP4"), (.gif, "GIF")], selection: model.choice.format,
                         width: 62, choose: model.choose)
            }
            group("Speed") {
                Segments(name: "Speed", options: Config.Speed.allCases.map { ($0, $0.label) }, selection: model.choice.speed,
                         width: 50, choose: model.choose)
            }
            group("Smaller") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 4) {
                        Segments(name: "Frame rate",
                                 options: Smaller.Frames.allCases.map { ($0, $0 == .native ? "All" : "\($0.rawValue)") },
                                 selection: model.choice.smaller.frames, width: 36, choose: model.choose)
                        Text("fps").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .help("Fewer frames make a smaller clip")
                    Divider()
                    Toggle("Half resolution", isOn: Binding(get: { model.choice.smaller.halfSize }, set: { _ in model.toggleHalfSize() }))
                        .toggleStyle(.switch).controlSize(.small)
                        .font(.system(size: 13))
                        .help("Half the width and height: about a quarter of the pixels")
                    Divider()
                    HStack {
                        Text("Target size").font(.system(size: 13))
                        Spacer()
                        TargetMenu(model: model)
                    }
                    Text("Lowers the frame rate, then the size, then a GIF's quality until the clip fits.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            group("Size") {
                Text(model.sizeLine.isEmpty ? " " : model.sizeLine)
                    .font(.system(size: 13)).monospacedDigit()
                    .foregroundStyle(model.estimating ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                CopyButton(model: model)
                Button("Save As…", action: saveAs)
                    .buttonStyle(PillButtonStyle())
                    .frame(maxWidth: .infinity)
                    .help("Saves a copy of the clip where you choose (Command-S)")
                if let note = model.note {
                    Text(note)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            Card {
                content()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// None, a few common limits, or any number of megabytes.
struct TargetMenu: View {
    @ObservedObject var model: ClipModel
    static let presets = [1, 2, 5, 10, 25]

    var body: some View {
        Menu {
            Button { model.chooseTarget(nil) } label: { item("None", chosen: model.choice.target == nil) }
            ForEach(Self.presets, id: \.self) { megabytes in
                Button { model.chooseTarget(megabytes * 1_000_000) } label: {
                    item("\(megabytes) MB", chosen: model.choice.target == megabytes * 1_000_000)
                }
            }
            Divider()
            Button("Other…") { askForTarget() }
        } label: {
            HStack(spacing: 6) {
                Text(model.choice.target.map(ClipModel.megabytes) ?? "None").monospacedDigit()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
        .accessibilityLabel("Target size")
        .accessibilityValue(model.choice.target.map(ClipModel.megabytes) ?? "None")
    }

    @ViewBuilder private func item(_ title: String, chosen: Bool) -> some View {
        if chosen { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func askForTarget() {
        let alert = NSAlert()
        alert.messageText = "Target size"
        alert.informativeText = "The most the clip may be, in megabytes."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "8"
        field.stringValue = model.choice.target.map { String(format: "%g", Double($0) / 1_000_000) } ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let bytes = Smaller.targetBytes(megabytes: field.stringValue.replacingOccurrences(of: ",", with: ".")) else { return }
        model.chooseTarget(bytes)
    }
}

/// A real window: while it is open the app has a Dock icon, menus and Command-Tab.
@MainActor
final class EditorWindow: NSObject, NSWindowDelegate {
    let model: ClipModel
    var onClose: () -> Void = {}
    private var window: NSWindow?
    private var monitor: Any?

    init(model: ClipModel) {
        self.model = model
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: EditorContent(model: model) { [weak self] in self?.saveAs() })
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = model.source.deletingPathExtension().lastPathComponent
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.delegate = self
        window.contentMinSize = NSSize(width: 860, height: 560)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1080, visible.width - 80), height: min(700, visible.height - 80))
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        model.start()
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() { window?.close() }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !(window.firstResponder is NSText) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "s" {
            saveAs()
            return true
        }
        guard flags.subtracting([.numericPad, .function]).isEmpty else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (KeyCode.space, _): model.togglePlay()
        case (KeyCode.left, _): model.step(-1)
        case (KeyCode.right, _): model.step(1)
        case (_, "i"): model.trimStart()
        case (_, "o"): model.trimEnd()
        case (KeyCode.returnKey, _), (KeyCode.keypadEnter, _): model.copy()
        default: return false
        }
        return true
    }

    private func saveAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.fileName
        panel.allowedContentTypes = [model.choice.format == .gif ? .gif : .mpeg4Movie]
        panel.directoryURL = model.saveFolder ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.model.copy(saveAs: url) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.stop()
        AppWindows.closed(window)
        window = nil
        onClose()
    }
}
