import Foundation

/// The first-run sketch, after Hex's onboarding: the usual way of showing someone a bug on your screen, played for
/// laughs, then the same moment with Capture Machine. Everything on screen is a function of the time since the sketch
/// started, so any moment can be rendered or tested.
public enum Sketch {
    public enum Half: Sendable, Equatable { case without, with }

    public enum Author: String, Sendable { case jay = "Jay", priya = "Priya", you = "You" }

    public enum Body: Sendable, Equatable {
        case text(String)
        /// A line from the chat itself, such as a pin.
        case note(String)
        /// A file you dropped in: it uploads for `uploadFails` seconds, then the chat refuses it as too big.
        case file(name: String, size: String)
        /// The converter's GIF: four frames a second, the wrong colours, a watermark.
        case badGIF
        /// Capture Machine's clip.
        case clip
    }

    public struct Message: Sendable, Equatable {
        public let at: Double
        public let author: Author?
        public let body: Body

        init(_ at: Double, _ author: Author?, _ body: Body) {
            self.at = at
            self.author = author
            self.body = body
        }
    }

    /// What the little Mac beside the chat shows.
    public enum Mac: Sendable, Equatable {
        case bug
        /// QuickTime in front: its File menu `open` once clicked, `chosen` once the cursor reaches New Screen Recording.
        case quickTimeMenu(open: Bool, chosen: Bool)
        case quickTimeRecording(seconds: Int)
        case savedFile
        case draggingFile(progress: Double)
        case converter(progress: Double)
        case converterDone
        case call
        /// Capture Machine's drop-down under its menu bar icon; `chosen` once Section is clicked.
        case dropDown(chosen: Bool)
        case selecting(progress: Double)
        case recording(seconds: Int)
        case copied
        case fixed
    }

    public struct Frame: Sendable, Equatable {
        public let time: Double
        public let half: Half
        /// Oldest first.
        public let messages: [Message]
        public let composer: String
        public let mac: Mac
        /// The one cursor on the little Mac, or nil while it's hidden.
        public let cursor: Cursor?
        /// 0 to 1 through the time-lapse: forty minutes pass while the converter crawls.
        public let skip: Double?
        /// The little Mac's menu bar clock, which the time-lapse runs forward.
        public let clock: String
        /// 0 to 1 through the rewind between the halves.
        public let rewind: Double?
        /// 0 to 1 through the confetti.
        public let confetti: Double?
        public let channel: String
        /// 0 to 1 as Safari opens; 0 before it does.
        public let browser: Double
        public let finished: Bool
    }

    /// The sketch opens on the chat alone (Tim, 2026-11-25: "there's always one spot for people to look at"): Jay asks,
    /// you answer, then Safari opens and you try checkout.
    public static let browserOpens = 3.4
    public static let browserOpening = 0.35
    public static let rewindStart = 33.2
    public static let rewindEnd = 34.6
    public static let skipStart = 22.6
    public static let skipLength = 1.8
    /// Minutes the time-lapse skips.
    public static let skipped = 40
    public static let confettiStart = 46.7
    public static let confettiLength = 2.3
    public static let duration = 49.0
    /// QuickTime comes to the front.
    public static let quickTimeStart = 10.7
    /// The browser comes to the front with the converter.
    public static let converterStart = 21.6
    /// The converter's GIF lands in the chat; its tab is closed.
    public static let gifPosted = 27.4
    /// Jay's FaceTime call comes in.
    public static let callStart = 31.6
    /// Capture Machine has copied the clip.
    public static let copiedStart = 40.15
    static let typingSpeed = 12.0

    /// Seconds a dropped file uploads before the chat refuses it.
    public static let uploadFails = 1.0

    // MARK: The cursor

    /// Places the cursor moves between. Each view of the sketch puts them where its own drawing has them.
    public enum Target: Sendable, Equatable {
        case rest, pay, fileMenu, newScreenRecording, quickTimeStop, desktopFile, chatDrop, menuIcon, section
        case selectionStart, selectionEnd
    }

    public struct Cursor: Sendable, Equatable {
        public let from: Target
        public let to: Target
        /// 0 to 1 along the move, not eased; a view eases it: in and out for a move, out for a drag.
        public let progress: Double
        /// The move is a drag: the button went down and held still before it started.
        public let drag: Bool
        public let pressed: Bool
        /// Carrying the recording, in the drag to the chat.
        public let carrying: Bool
        public let opacity: Double
    }

    struct Move {
        let start: Double
        let to: Target
        let duration: Double
        /// A click when the move ends.
        var click = false
        /// The button goes down and holds still for `hold` seconds, then stays down through the move.
        var drag = false
        var hold = 0.0
        var end: Double { start + hold + duration }
    }

    /// Runs of moves with the cursor in view; it fades in at the first move and out 0.8 s after the last. A move
    /// takes time for its distance, waits for the app switcher to go, and starts after the last click has let go.
    static let gestures: [[Move]] = [
        [Move(start: 4.3, to: .pay, duration: 0.55, click: true)],
        [Move(start: 11.3, to: .fileMenu, duration: 0.5, click: true),
         Move(start: 11.95, to: .newScreenRecording, duration: 0.2, click: true),
         Move(start: 13.95, to: .quickTimeStop, duration: 0.5, click: true),
         Move(start: 15.3, to: .desktopFile, duration: 0.55),
         Move(start: 15.85, to: .chatDrop, duration: 0.9, drag: true, hold: 0.12)],
        [Move(start: 35.9, to: .menuIcon, duration: 0.55, click: true),
         Move(start: 36.75, to: .section, duration: 0.4, click: true),
         Move(start: 37.5, to: .selectionStart, duration: 0.3),
         Move(start: 37.8, to: .selectionEnd, duration: 0.45, drag: true, hold: 0.12),
         Move(start: 38.55, to: .pay, duration: 0.35, click: true),
         Move(start: 39.6, to: .menuIcon, duration: 0.5, click: true)],
        [Move(start: 44.2, to: .pay, duration: 0.45, click: true)],
    ]

    static func cursor(at t: Double) -> Cursor? {
        guard let moves = gestures.first(where: { t >= $0[0].start && t < $0[$0.count - 1].end + 0.8 }) else { return nil }
        let opacity = min(1, (t - moves[0].start) / 0.15, (moves[moves.count - 1].end + 0.8 - t) / 0.3)
        let index = moves.lastIndex { $0.start <= t } ?? 0
        let move = moves[index]
        let from = index == 0 ? Target.rest : moves[index - 1].to
        let progress = min(1, max(0, (t - move.start - move.hold) / move.duration))
        let pressed = move.drag ? t >= move.start && t < move.end : move.click && t >= move.end && t < move.end + 0.15
        return Cursor(from: from, to: move.to, progress: progress, drag: move.drag, pressed: pressed,
                      carrying: move.drag && move.to == .chatDrop && t < move.end, opacity: max(0, opacity))
    }

    /// Seconds since Pay was last clicked, or nil while the page shows Pay: before the first click, and from the
    /// start of each new reach for it until the click.
    public static func sincePayClick(at t: Double) -> Double? {
        let reaches = gestures.flatMap { $0 }.filter { $0.to == .pay && $0.start <= t }
        guard let last = reaches.last, t >= last.end else { return nil }
        return t - last.end
    }

    struct Typing {
        let start: Double
        let text: String
        var sent: Double { start + Double(text.count) / Sketch.typingSpeed + 0.15 }
    }

    static let reply = Typing(start: 1.4, text: "I'll check it out")

    /// Both halves start from here. Priya and Jay answer while checkout hangs.
    static let opening: [Message] = [
        Message(0.5, .jay, .text("is checkout broken on staging?")),
        Message(reply.sent, .you, .text(reply.text)),
        Message(6.5, .priya, .text("works for me")),
        Message(7.7, .jay, .text("can someone show me what you're seeing")),
    ]

    /// Where the rewind returns to.
    static var question: Message { opening[3] }

    static let withoutTyping = [
        reply,
        Typing(start: 8.6, text: "on it, recording now"),
        Typing(start: 18.3, text: "one sec, making it smaller"),
    ]

    static let withoutMessages: [Message] = opening + [
        Message(withoutTyping[1].sent, .you, .text(withoutTyping[1].text)),
        Message(16.9, .you, .file(name: "Screen Recording 2026-11-20 at 4.31.07 PM.mov", size: "214.6 MB")),
        Message(withoutTyping[2].sent, .you, .text(withoutTyping[2].text)),
        Message(24.6, .jay, .text("hello??")),
        Message(25.6, .jay, .text("launch is in 20 min")),
        Message(gifPosted, .you, .badGIF),
        Message(28.4, .jay, .text("is that a slideshow")),
        Message(29.6, .priya, .text("why is it purple")),
        Message(30.8, .jay, .text("nvm i'll just call you")),
    ]

    static let withTyping = [Typing(start: 35.0, text: "on it")]

    static let withMessages: [Message] = opening + [
        Message(withTyping[0].sent, .you, .text(withTyping[0].text)),
        Message(40.7, .you, .clip),
        Message(41.7, .jay, .text("OH. the spinner never stops")),
        Message(42.7, .priya, .text("found it, fixing")),
        Message(43.7, .priya, .text("shipped")),
        Message(45.3, .jay, .text("ok what did you record that with")),
        Message(46.1, nil, .note("Jay pinned your clip")),
        Message(confettiStart, nil, .note("Jay renamed the channel to #hall-of-fame")),
    ]

    public static func frame(at time: Double) -> Frame {
        let t = min(max(time, 0), duration)
        let half: Half = t < rewindEnd ? .without : .with
        var rewind: Double?
        let messages: [Message]
        let composer: String
        switch half {
        case .without where t >= rewindStart:
            let progress = (t - rewindStart) / (rewindEnd - rewindStart)
            rewind = progress
            // The chat runs backwards to Jay's question.
            let cutoff = rewindStart - progress * (rewindStart - question.at)
            messages = withoutMessages.filter { $0.at <= cutoff }
            composer = ""
        case .without:
            messages = withoutMessages.filter { $0.at <= t }
            composer = typed(withoutTyping, at: t)
        case .with:
            messages = withMessages.filter { $0.at <= t }
            composer = typed(withTyping, at: t)
        }
        let skip = (skipStart ..< skipStart + skipLength).contains(t) ? (t - skipStart) / skipLength : nil
        let confetti = (confettiStart ..< confettiStart + confettiLength).contains(t) ? (t - confettiStart) / confettiLength : nil
        let browser = min(1, max(0, (t - browserOpens) / browserOpening))
        return Frame(time: t, half: half, messages: messages, composer: composer, mac: mac(at: t), cursor: cursor(at: t), skip: skip,
                     clock: clock(at: t), rewind: rewind, confetti: confetti, channel: t >= confettiStart ? "hall-of-fame" : "checkout",
                     browser: browser, finished: time >= duration)
    }

    /// 4:31 PM, run forward through the time-lapse, and back to 4:31 after the rewind.
    static func clock(at t: Double) -> String {
        var passed = 0
        if t < rewindEnd, t >= skipStart {
            let x = min(1, (t - skipStart) / skipLength)
            passed = Int((Double(skipped) * x * x * (3 - 2 * x)).rounded())
        }
        let minutes = 31 + passed
        return String(format: "%d:%02d PM", 4 + minutes / 60, minutes % 60)
    }

    static func typed(_ typings: [Typing], at t: Double) -> String {
        guard let typing = typings.first(where: { $0.start <= t && t < $0.sent }) else { return "" }
        let count = min(typing.text.count, Int((t - typing.start) * typingSpeed))
        return String(typing.text.prefix(count))
    }

    static func mac(at t: Double) -> Mac {
        func progress(_ from: Double, _ to: Double) -> Double { min(max((t - from) / (to - from), 0), 1) }
        switch t {
        case ..<quickTimeStart: return .bug
        case ..<12.2: return .quickTimeMenu(open: t >= 11.8, chosen: t >= 12.1)
        case ..<14.6: return .quickTimeRecording(seconds: Int(progress(12.2, 14.6) * 3.99))
        case ..<15.85: return .savedFile
        case ..<16.87: return .draggingFile(progress: progress(15.97, 16.87))
        case ..<converterStart: return .savedFile
        case ..<skipStart: return .converter(progress: 0.03 * progress(converterStart, skipStart))
        case ..<(skipStart + skipLength): return .converter(progress: 0.03 + 0.59 * progress(skipStart, skipStart + skipLength))
        case ..<25.2: return .converter(progress: 0.62 + 0.37 * progress(skipStart + skipLength, 25.2))
        case ..<callStart: return .converterDone
        case ..<rewindEnd: return .call
        case ..<36.5: return .bug
        case ..<37.5: return .dropDown(chosen: t >= 37.15)
        case ..<38.4: return .selecting(progress: progress(37.92, 38.37))
        case ..<copiedStart: return .recording(seconds: Int(progress(38.4, copiedStart) * 3.99))
        case ..<41.2: return .copied
        case ..<44.2: return .bug
        default: return .fixed
        }
    }
}
