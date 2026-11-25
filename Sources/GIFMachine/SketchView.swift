import AppKit
import GIFMachineCore
import SwiftUI

// The first-run sketch on screen, filmed like a screen recording: one Mac desktop with the team chat and the staging
// checkout side by side (`SketchDesktop.swift`), and a camera that stays wide while both matter and zooms to stress a
// moment. Every view here draws one `Sketch.Frame`, so a frame renders the same on screen, in `--render` and in a test.

/// Plays the sketch once. The timeline pauses at the end so a finished sketch costs nothing.
@MainActor
final class SketchPlayer: ObservableObject {
    @Published private(set) var finished = false
    private var began = Date()
    private var timer: Timer?

    func time(at date: Date) -> Double { date.timeIntervalSince(began) }

    func play() {
        began = Date()
        finished = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Sketch.duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished = true }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct SketchPage: View {
    @ObservedObject var model: OnboardingModel
    @StateObject private var player = SketchPlayer()

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(paused: player.finished)) { context in
                let frame = Sketch.frame(at: player.finished ? Sketch.duration : player.time(at: context.date))
                SketchStage(frame: frame, allowed: model.allowed)
                    .onChange(of: frame.messages.count) { before, now in
                        if now > before, let message = frame.messages.last { SketchSound.play(for: message) }
                    }
            }
            .scaleEffect(OnboardingLayout.scale, anchor: .topLeading)
            .frame(width: OnboardingLayout.stage.width * OnboardingLayout.scale,
                   height: OnboardingLayout.stage.height * OnboardingLayout.scale, alignment: .topLeading)
            HStack(spacing: 10) {
                Spacer()
                if player.finished {
                    Button("Replay") { player.play() }.buttonStyle(PillButtonStyle())
                    Button("Continue") { model.next() }.buttonStyle(PillButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip") { model.next() }.buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            // Lined up with the recording's right edge, 30 points in at the sketch's own size.
            .padding(.horizontal, SketchStage.screen.minX * OnboardingLayout.scale)
            .padding(.bottom, 20)
        }
        .onAppear { player.play() }
        .onDisappear { player.stop() }
    }
}

/// Each message makes a sound as it's sent or arrives, so the eye goes to the chat (Tim, 2026-11-25). The system's own
/// sounds: Tink for yours, Pop for the others'. Notes from the chat itself are silent.
@MainActor
enum SketchSound {
    private static let sent = NSSound(named: "Tink")
    private static let received = NSSound(named: "Pop")

    static func play(for message: Sketch.Message) {
        guard let author = message.author, let sound = (author == .you ? sent : received)?.copy() as? NSSound else { return }
        sound.volume = 0.5
        sound.play()
    }
}

struct SketchStage: View {
    let frame: Sketch.Frame
    let allowed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// The recording fills the window between the title and the buttons: 30 points in from each side, 16 below the title
    /// and 16 above the buttons, which line up with its right edge.
    static let screen = CGRect(x: 30, y: 96.5, width: 700, height: 437.5)

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 8) {
                PermissionPill(allowed: allowed)
                SketchTitle(half: frame.half)
            }
            .frame(width: 760)
            .padding(.top, 20)

            Filmed(frame: frame, reduceMotion: reduceMotion)
                .frame(width: Self.screen.width, height: Self.screen.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.1), lineWidth: 1))
                .overlay {
                    if let skip = frame.skip {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.45 * Motion.hold(skip)))
                            TimeLapse(progress: skip, reduceMotion: reduceMotion)
                        }
                    }
                }
                .overlay { if let rewind = frame.rewind { RewindMark(progress: rewind) } }
                .overlay { if let confetti = frame.confetti, !reduceMotion { Confetti(progress: confetti) } }
                .offset(x: Self.screen.minX, y: Self.screen.minY)
        }
        .frame(width: 760, height: 550, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A short screencast. Showing a bug the usual way takes forty minutes, an online converter and a phone call. With Capture Machine it's one click in the menu bar.")
    }
}

/// The framings the camera moves between.
private enum Shot: Equatable {
    case wide, chat, browser

    /// Centre of the framing in desktop points, and the zoom: 1 shows the whole desktop.
    var camera: (x: Double, y: Double, zoom: Double) {
        switch self {
        case .wide: (380, 237.5, 1)
        // The chat's latest messages, close, 6 points under it; the frame's edge falls between the order's names and prices.
        case .chat: (237.5, 310.5, 1.6)
        // The browser and the menu bar above it, 22 points of wallpaper on either side, the chat just out of frame.
        case .browser: (538, 138.7, 1.712)
        }
    }
}

/// When the camera starts moving, and to what. Close on the chat until Safari opens; then wide while things happen in
/// both places, and close only to stress the refused upload, the bad GIF and the replies, the call, Capture Machine's
/// drop-down and selection, and the paste. Each move settles before the beat it frames.
private let shots: [(at: Double, shot: Shot)] = [
    (0, .chat), (Sketch.browserOpens - 0.1, .wide), (16.95, .chat), (20.8, .wide), (27.0, .chat), (30.95, .browser),
    (33.0, .wide), (35.7, .browser), (40.2, .chat), (43.9, .wide),
]
private let move = 0.8

private func camera(at t: Double, reduceMotion: Bool) -> (x: Double, y: Double, zoom: Double) {
    guard let index = shots.lastIndex(where: { $0.at <= t }) else { return Shot.wide.camera }
    let to = shots[index].shot.camera
    guard index > 0, !reduceMotion else { return to }
    let from = shots[index - 1].shot.camera
    let k = Motion.easeInOut((t - shots[index].at) / move)
    // Zoom moves on a log scale, so zooming in and out feel the same speed.
    let zoom = exp(log(from.zoom) + (log(to.zoom) - log(from.zoom)) * k)
    return (from.x + (to.x - from.x) * k, from.y + (to.y - from.y) * k, zoom)
}

/// The desktop and its cursor, framed by the camera.
private struct Filmed: View {
    let frame: Sketch.Frame
    let reduceMotion: Bool

    var body: some View {
        let size = SketchDesk.size
        let camera = camera(at: frame.time, reduceMotion: reduceMotion)
        let scale = SketchStage.screen.width / size.width * camera.zoom
        let halfWidth = size.width / camera.zoom / 2, halfHeight = size.height / camera.zoom / 2
        let x = min(max(camera.x, halfWidth), size.width - halfWidth)
        let y = min(max(camera.y, halfHeight), size.height - halfHeight)
        ZStack(alignment: .topLeading) {
            DeskScene(frame: frame)
                .blur(radius: 5 / scale * Motion.hold(frame.skip))
            if let cursor = frame.cursor {
                SketchCursor(cursor: cursor) { SketchDesk.point($0, frame) }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: SketchStage.screen.width / 2 - x * scale, y: SketchStage.screen.height / 2 - y * scale)
        .frame(width: SketchStage.screen.width, height: SketchStage.screen.height, alignment: .topLeading)
    }
}

/// The macOS arrow, black with a white edge, its tip at the view's top left.
struct ArrowCursor: View {
    var body: some View {
        let arrow = Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 16.5))
            path.addLine(to: CGPoint(x: 4, y: 12.8))
            path.addLine(to: CGPoint(x: 6.9, y: 19))
            path.addLine(to: CGPoint(x: 9.5, y: 17.8))
            path.addLine(to: CGPoint(x: 6.7, y: 11.8))
            path.addLine(to: CGPoint(x: 11.8, y: 11.8))
            path.closeSubpath()
        }
        ZStack(alignment: .topLeading) {
            arrow.stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
            arrow.fill(Color.black)
        }
        .frame(width: 13, height: 20, alignment: .topLeading)
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}

enum Motion {
    /// 0 to 1 and back over the time-lapse: up in its first 0.25 s, down in its last 0.3 s.
    static func hold(_ progress: Double?) -> Double {
        guard let progress else { return 0 }
        let seconds = progress * Sketch.skipLength
        return max(0, min(1, seconds / 0.25, (Sketch.skipLength - seconds) / 0.3))
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(max(x, 0), 1), 3) }

    static func easeInOut(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}

private struct PermissionPill: View {
    let allowed: Bool

    var body: some View {
        Label(allowed ? "Screen Recording on" : "Screen Recording off", systemImage: allowed ? "checkmark.circle" : "circle.dashed")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

private struct SketchTitle: View {
    let half: Sketch.Half

    var body: some View {
        Text(half == .without ? "Without Capture Machine" : "With Capture Machine")
            .font(.system(size: 22, weight: .semibold))
    }
}

// MARK: The chat

struct ChatCard: View {
    let frame: Sketch.Frame
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("#\(frame.channel)").font(.system(size: 13, weight: .semibold))
                    Text("Jay, Priya and you").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Launch today", systemImage: "clock").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(frame.messages.suffix(12).enumerated()), id: \.offset) { _, message in
                    MessageRow(message: message, time: frame.time)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: width, height: height - 101, alignment: .bottom)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay { DropTarget(frame: frame) }
            Composer(text: frame.composer, channel: frame.channel)
                .frame(height: 52)
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Surface.card))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Surface.border, lineWidth: 1))
    }
}

/// What the chat shows while a file is carried over it.
private struct DropTarget: View {
    let frame: Sketch.Frame

    var body: some View {
        if case .draggingFile(let progress) = frame.mac, progress > 0.6 {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Surface.card.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .overlay(Label("Upload to #\(frame.channel)", systemImage: "arrow.up.doc").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor))
                .padding(8)
                .opacity(min(1, (progress - 0.6) / 0.12))
        }
    }
}

private struct Composer: View {
    let text: String
    let channel: String

    var body: some View {
        HStack(spacing: 0) {
            Text(text.isEmpty ? "Message #\(channel)" : text).foregroundStyle(text.isEmpty ? .secondary : .primary)
            if !text.isEmpty { Rectangle().fill(Color.primary).frame(width: 1.5, height: 14).padding(.leading, 1) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Surface.border, lineWidth: 1))
        .padding(10)
    }
}

private struct MessageRow: View {
    let message: Sketch.Message
    let time: Double

    var body: some View {
        let shown = Motion.easeOut((time - message.at) / 0.18)
        content
            .opacity(shown)
            .scaleEffect(0.92 + 0.08 * shown, anchor: message.author == .you ? .bottomTrailing : .bottomLeading)
    }

    @ViewBuilder private var content: some View {
        switch (message.author, message.body) {
        case (_, .note(let text)):
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case (let author?, let body):
            let mine = author == .you
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if !mine { Text(author.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                Bubble(content: body, mine: mine, time: time, sent: message.at)
            }
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        case (nil, _):
            EmptyView()
        }
    }
}

private struct Bubble: View {
    let content: Sketch.Body
    let mine: Bool
    let time: Double
    let sent: Double

    var body: some View {
        switch content {
        case .text(let text):
            Text(text).font(.system(size: 12))
                .foregroundStyle(mine ? Color(nsColor: .windowBackgroundColor) : .primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(mine ? Color.primary.opacity(0.85) : Color.primary.opacity(0.07)))
        case .file(let name, let size):
            FileBubble(name: name, size: size, since: time - sent)
        case .badGIF:
            Media(caption: "converted.gif · 38.2 MB") { CheckoutMock(time: time, style: .bad) }
        case .clip:
            Media(caption: "checkout.mp4 · 0:03") { CheckoutMock(time: time, style: .live) }
        case .note:
            EmptyView()
        }
    }
}

/// A dropped file: it uploads for `Sketch.uploadFails` seconds, then the chat refuses it in red.
private struct FileBubble: View {
    let name: String
    let size: String
    let since: Double

    var body: some View {
        let failed = since >= Sketch.uploadFails
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "film").font(.system(size: 16)).foregroundStyle(failed ? Color.red : .primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if failed {
                        Text("\(size) · Upload failed").font(.system(size: 10)).foregroundStyle(.red)
                    } else {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(Color.accentColor).frame(width: max(3, 130 * 0.4 * min(1, since / Sketch.uploadFails)))
                        }
                        .frame(width: 130, height: 3)
                    }
                }
                Spacer(minLength: 0)
                if failed {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 14)).foregroundStyle(.red)
                } else {
                    Circle().trim(from: 0, to: 0.7).stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 12, height: 12).rotationEffect(.degrees(since * 400))
                }
            }
            .padding(8).frame(width: 230, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(failed ? Color.red.opacity(0.08) : Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(failed ? Color.red.opacity(0.6) : .clear, lineWidth: 1))
            if failed {
                Label("Files over 100 MB can't be shared here.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.red)
            }
        }
    }
}

private struct Media<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            content.frame(width: 168, height: 100).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Surface.border, lineWidth: 1))
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

// MARK: The bug

/// The bug as the chat's clips show it: the Pay button spins forever, and the clip loops, as a GIF does. `.bad` is the
/// converter's GIF of it: four frames a second, a purple cast, a watermark.
struct CheckoutMock: View {
    enum Style { case live, fixed, bad }
    let time: Double
    let style: Style
    var loops = true

    var body: some View {
        let at = style == .bad ? (time * 4).rounded(.down) / 4 : time
        let since = at.truncatingRemainder(dividingBy: 2.4)
        let pressed = loops ? since >= 0.8 : Sketch.sincePayClick(at: at) != nil
        GeometryReader { geometry in
            let size = geometry.size
            let button = CGPoint(x: size.width * 0.5, y: size.height * 0.74)
            let start = CGPoint(x: size.width * 0.86, y: size.height * 0.22)
            let move = Motion.easeInOut(since / 0.8)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                VStack(alignment: .leading, spacing: size.height * 0.06) {
                    Text("Order summary").font(.system(size: size.height * 0.11, weight: .semibold))
                    HStack {
                        Text("Total")
                        Spacer()
                        Text("$48.00").monospacedDigit()
                    }
                    .font(.system(size: size.height * 0.09))
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(size.height * 0.1)
                PayButton(state: !pressed ? .ready : style == .fixed ? .paid : .spinning(at), height: size.height * 0.2)
                    .frame(width: size.width * 0.6)
                    .position(button)
                if loops {
                    Image(systemName: "cursorarrow").font(.system(size: size.height * 0.14))
                        .foregroundStyle(.primary)
                        .shadow(color: .black.opacity(0.2), radius: 1)
                        .position(x: start.x + (button.x - start.x) * move + 4, y: start.y + (button.y - start.y) * move + 6)
                }
                if style == .bad {
                    Color.purple.opacity(0.22).blendMode(.multiply)
                    Dither().opacity(0.18)
                    Text("FREEGIFCONVERTER.ONLINE")
                        .font(.system(size: size.height * 0.1, weight: .black))
                        .foregroundStyle(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.4), radius: 1)
                        .rotationEffect(.degrees(-18))
                        .position(x: size.width / 2, y: size.height / 2)
                }
            }
        }
    }
}

struct PayButton: View {
    enum State { case ready, spinning(Double), paid }
    let state: State
    let height: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: height * 0.3, style: .continuous).fill(Color.primary.opacity(0.85))
            Group {
                switch state {
                case .ready: Text("Pay")
                case .spinning(let time):
                    Circle().trim(from: 0, to: 0.7)
                        .stroke(Color(nsColor: .windowBackgroundColor), style: StrokeStyle(lineWidth: height * 0.1, lineCap: .round))
                        .frame(width: height * 0.5, height: height * 0.5)
                        .rotationEffect(.degrees(time * 400))
                case .paid: Label("Paid", systemImage: "checkmark")
                }
            }
            .font(.system(size: height * 0.45, weight: .semibold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        }
        .frame(height: height)
    }
}

private struct Dither: View {
    var body: some View {
        Canvas { context, size in
            var y = 0.0
            var row = 0
            while y < size.height {
                var x = row.isMultiple(of: 2) ? 0.0 : 2.0
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.black))
                    x += 4
                }
                y += 2
                row += 1
            }
        }
    }
}

// MARK: Set pieces

/// Forty minutes passing: a card with a clock whose hands spin, while the menu bar clock runs forward behind it.
private struct TimeLapse: View {
    let progress: Double
    let reduceMotion: Bool

    var body: some View {
        let shown = Motion.hold(progress)
        HStack(spacing: 12) {
            ClockFace(turn: reduceMotion ? 0 : progress)
                .frame(width: 30, height: 30)
            Text("\(Sketch.skipped) minutes later")
                .font(.system(size: 20, weight: .semibold))
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().strokeBorder(Surface.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .opacity(shown)
        .offset(y: reduceMotion ? 0 : 8 * (1 - Motion.easeOut(shown)))
    }
}

/// The minute hand makes two turns over the time-lapse, the hour hand a sliver.
private struct ClockFace: View {
    let turn: Double

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 1.5
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .foreground, lineWidth: 2.5)
            func hand(_ angle: Double, _ length: Double, _ width: Double) {
                var path = Path()
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x + sin(angle) * length, y: center.y - cos(angle) * length))
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand(.pi * 2 * (31.0 / 60 + 2 * turn), radius * 0.72, 2)
            hand(.pi * 2 * ((4 + 31.0 / 60) / 12 + turn / 18), radius * 0.45, 2.5)
        }
        .foregroundStyle(.primary)
    }
}

private struct RewindMark: View {
    let progress: Double

    var body: some View {
        Image(systemName: "backward.fill")
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(.primary)
            .opacity(sin(.pi * progress))
    }
}

private struct Confetti: View {
    let progress: Double
    private static let colors: [Color] = [.pink, .orange, .yellow, .green, .blue, .purple]

    var body: some View {
        Canvas { context, size in
            for index in 0..<90 {
                func random(_ salt: Int) -> Double {
                    let value = sin(Double(index * 127 + salt * 311)) * 43758.5453
                    return value - value.rounded(.down)
                }
                let fall = progress * size.height * (0.9 + random(3) * 0.7)
                let x = random(1) * size.width + sin(progress * 7 + Double(index)) * 16
                let y = -20 - random(2) * 140 + fall
                var piece = context
                piece.translateBy(x: x, y: y)
                piece.rotate(by: .degrees(progress * 900 * (random(4) - 0.5)))
                piece.opacity = progress > 0.8 ? (1 - progress) / 0.2 : 1
                piece.fill(Path(CGRect(x: -3, y: -5, width: 6, height: 10)), with: .color(Self.colors[index % Self.colors.count]))
            }
        }
        .allowsHitTesting(false)
    }
}
