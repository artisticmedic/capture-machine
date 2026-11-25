import AppKit
import AVFoundation
import GIFMachineCore

/// Hands a recording out: makes the clip in the chosen format and speed, puts it in the save folder and on the clipboard.
@MainActor
enum Delivery {
    /// What a clip is made as.
    struct Output: Equatable {
        var format: Config.Format
        var speed: Config.Speed
        var smaller = Smaller()
        /// The part kept, in seconds from the recording's first frame; nil keeps it all.
        var trim: ClosedRange<Double>?
        /// Target size: a file-size limit in bytes; nil for none.
        var target: Int?
    }

    /// What Target size settled on.
    struct Fitted: Equatable {
        let smaller: Smaller
        /// An MP4's average bits a second, when it had to be set.
        let bitRate: Double?
        let bytes: Int
        let fits: Bool
    }

    struct Made {
        let url: URL
        let fitted: Fitted?
    }

    struct Handout {
        let url: URL
        /// Set when saving to the folder failed; the clip stayed in the app's Recordings folder.
        let saveFailure: String?
        var fitted: Fitted?
        /// It went on the clipboard; it doesn't when something else was copied while it was made.
        var copied = true
    }

    /// gifski inside the app; in a build run from `.build`, the one scripts/build-gifski.sh made.
    static var gifski: URL {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gifski")
        if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        return Bundle.main.executableURL!.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("gifski/out/bin/gifski")
    }

    /// `recordedFPS` is the rate the recording asked for, which sets a GIF's rate with the speed. `progress` reports a
    /// GIF's making from 0 to 1.
    /// Each clip is a file of its own: the clips handed out before it stay, so a clipboard history can still paste them.
    /// With `temporary` (saving off), the clipboard holds the clip from the Clipboard folder.
    /// Something copied while the clip was made stays on the clipboard: the clip is then saved but not copied.
    static func handOut(source: URL, output: Output, recordedFPS: Int, saveFolder: URL?, temporary: Bool = false,
                        progress: @escaping @Sendable (Double) -> Void = { _ in },
                        fitting: @escaping @Sendable () -> Void = {}) async throws -> Handout {
        let clipboard = Clipboard.count
        let made = try await make(source: source, output: output, recordedFPS: recordedFPS, progress: progress, fitting: fitting)
        let clip = made.url
        // Stopped while the clip was made: nothing is placed or copied.
        if Task.isCancelled {
            if clip != source { try? FileManager.default.removeItem(at: clip) }
            throw CancellationError()
        }
        var url = clip
        var saveFailure: String?
        if let saveFolder {
            do {
                url = try Clip.place(clip, source: source, in: saveFolder)
            } catch {
                saveFailure = "Not saved to \(Paths.display(saveFolder)): \(error.localizedDescription)"
            }
        }
        let copies = Clipboard.count == clipboard
        if copies { url = try Clipboard.publish(url, temporary: temporary, source: source) }
        return Handout(url: url, saveFailure: saveFailure, fitted: made.fitted, copied: copies)
    }

    /// Makes the clip beside the recording: the recording itself for an MP4 at 1×, otherwise a new file. With a target
    /// size, `fitting` runs first, while Target size looks for the settings that fit.
    static func make(source: URL, output: Output, recordedFPS: Int, progress: @escaping @Sendable (Double) -> Void = { _ in },
                     fitting: @escaping @Sendable () -> Void = {}) async throws -> Made {
        guard let target = output.target else {
            return Made(url: try await build(source: source, output: output, recordedFPS: recordedFPS, smaller: output.smaller,
                                             bitRate: nil, progress: progress), fitted: nil)
        }
        fitting()
        return output.format == .gif
            ? try await fitGIF(source: source, output: output, target: target, recordedFPS: recordedFPS, progress: progress)
            : try await fitMP4(source: source, output: output, target: target, recordedFPS: recordedFPS, progress: progress)
    }

    private static func build(source: URL, output: Output, recordedFPS: Int, smaller: Smaller, bitRate: Double?,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard output.format == .gif else {
            return try await Clip.make(from: source, speed: output.speed, trim: output.trim, smaller: smaller, bitRate: bitRate)
        }
        let movie = try await Clip.make(from: source, speed: output.speed, trim: output.trim)
        defer { if movie != source { try? FileManager.default.removeItem(at: movie) } }
        let base = source.deletingPathExtension().lastPathComponent
        let suffix = (output.speed == .normal ? "" : " \(output.speed.fileSuffix)") + (output.trim == nil ? "" : " trimmed")
            + (smaller == Smaller() ? "" : " smaller")
        let gif = Paths.unusedURL(for: "\(base)\(suffix).gif", in: source.deletingLastPathComponent())
        try await GIFMaker.make(from: movie, to: gif, options: smaller, clipFPS: Double(recordedFPS) * output.speed.rawValue,
                                gifski: gifski, progress: progress)
        return gif
    }

    /// The estimate aims under the target by this much, so the clip it predicts usually fits the first time.
    private static let margin = 0.92

    /// Steps down the ladder: the first rung whose estimate fits is made, and while the made GIF is still over, the next.
    /// Fewer frames shrink a GIF about in proportion, so estimating starts at the first frame-rate rung predicted to fit.
    private static func fitGIF(source: URL, output: Output, target: Int, recordedFPS: Int,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> Made {
        let rungs = output.smaller.ladder(gif: true)
        let clipFPS = Double(recordedFPS) * output.speed.rawValue
        let budget = Double(target) * margin
        func estimate(_ index: Int) async throws -> Int {
            try await GIFMaker.estimate(source: source, trim: output.trim, speed: output.speed.rawValue, options: rungs[index],
                                        recordedFPS: Double(recordedFPS), gifski: gifski)
        }
        var index = 0
        let first = try await estimate(0)
        if Double(first) > budget {
            let rate = Double(rungs[0].fps(clipFPS: clipFPS))
            index = rungs.indices.first { index in
                index > 0 && (rungs[index].halfSize != rungs[0].halfSize || rungs[index].quality != rungs[0].quality
                    || Double(first) * Double(rungs[index].fps(clipFPS: clipFPS)) / rate <= budget)
            } ?? rungs.count - 1
            while index < rungs.count - 1, Double(try await estimate(index)) > budget { index += 1 }
        }
        while true {
            try Task.checkCancellation()
            let url = try await build(source: source, output: output, recordedFPS: recordedFPS, smaller: rungs[index], bitRate: nil,
                                      progress: progress)
            let bytes = size(of: url)
            if bytes <= target || index == rungs.count - 1 {
                return Made(url: url, fitted: Fitted(smaller: rungs[index], bitRate: nil, bytes: bytes, fits: bytes <= target))
            }
            try? FileManager.default.removeItem(at: url)
            index += 1
        }
    }

    /// An MP4 that already fits is kept as it is. Otherwise its average bit rate is set to fit; when that would leave too
    /// few bits for each pixel of each frame, it first steps down the frame rate, then the size. Frames are counted from
    /// the file: a recording of a screen that sits still has far fewer than its length times its frame rate. A made clip
    /// still over the target is made again at a proportionally lower rate, twice at most.
    private static func fitMP4(source: URL, output: Output, target: Int, recordedFPS: Int,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> Made {
        let asset = AVURLAsset(url: source)
        let length = try await asset.load(.duration).seconds
        let pixels = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? CGSize(width: 1600, height: 1000)
        // The recording as it is, when it already fits.
        if output.speed == .normal, output.trim == nil, !output.smaller.changesMP4, size(of: source) <= target {
            return Made(url: source, fitted: Fitted(smaller: output.smaller, bitRate: nil, bytes: size(of: source), fits: true))
        }
        let seconds = max(0.1, (output.trim.map { $0.upperBound - $0.lowerBound } ?? length) / output.speed.rawValue)
        if Double(estimateMP4(source: source, output: output, length: length, recordedFPS: recordedFPS)) <= Double(target) * margin {
            let url = try await build(source: source, output: output, recordedFPS: recordedFPS, smaller: output.smaller, bitRate: nil,
                                      progress: progress)
            let bytes = size(of: url)
            if bytes <= target { return Made(url: url, fitted: Fitted(smaller: output.smaller, bitRate: nil, bytes: bytes, fits: true)) }
            if url != source { try? FileManager.default.removeItem(at: url) }
        }
        let rungs = output.smaller.ladder(gif: false)
        var bitRate = Double(target) * 8 * margin / seconds
        let times = try await Retimer.frameTimes(source)
        let index = rungs.firstIndex { rung in
            let area = Double(pixels.width * pixels.height) * (rung.halfSize ? 0.25 : 1)
            let frames = Retimer.keptFrames(times, size: pixels, speed: output.speed.rawValue, trim: output.trim, fps: rung.mp4FPS,
                                            halfSize: rung.halfSize)
            return bitRate * seconds >= 0.03 * area * Double(frames)
        } ?? rungs.count - 1
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let url = try await build(source: source, output: output, recordedFPS: recordedFPS, smaller: rungs[index], bitRate: bitRate,
                                      progress: progress)
            let bytes = size(of: url)
            if bytes <= target || attempt == 2 {
                return Made(url: url, fitted: Fitted(smaller: rungs[index], bitRate: bitRate, bytes: bytes, fits: bytes <= target))
            }
            try? FileManager.default.removeItem(at: url)
            bitRate *= Double(target) / Double(bytes) * margin
        }
        throw CancellationError()
    }

    /// About how big the clip would be, without Target size. A GIF is sampled with gifski; an MP4 is reckoned from the
    /// recording's own size.
    static func estimate(source: URL, output: Output, recordedFPS: Int) async throws -> Int {
        guard output.format == .gif else {
            let length = try await AVURLAsset(url: source).load(.duration).seconds
            return estimateMP4(source: source, output: output, length: length, recordedFPS: recordedFPS)
        }
        return try await GIFMaker.estimate(source: source, trim: output.trim, speed: output.speed.rawValue, options: output.smaller,
                                           recordedFPS: Double(recordedFPS), gifski: gifski)
    }

    /// The recording's bytes for the kept part, less for dropped frames and half size. Slowing down keeps every frame, so
    /// it costs nothing.
    private static func estimateMP4(source: URL, output: Output, length: Double, recordedFPS: Int) -> Int {
        var bytes = Double(size(of: source))
        if let trim = output.trim, length > 0 { bytes *= (trim.upperBound - trim.lowerBound) / length }
        let clipFPS = Double(recordedFPS) * min(1, output.speed.rawValue)
        var kept = output.speed.rawValue > 1 ? 0.5 : 1
        if let fps = output.smaller.mp4FPS { kept = min(kept, Double(fps) / max(1, clipFPS)) }
        // Dropped frames save less than their share: what changes between kept frames costs more to encode.
        bytes *= pow(kept, 0.7)
        if output.smaller.halfSize { bytes *= 0.4 }
        return Int(bytes)
    }

    private static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Hands out a finished recording as `config` says, and reports the timings. An MP4 goes on the clipboard at the speed
    /// in Settings, so at another speed Stop waits while it's made. Nothing goes on the clipboard for the GIF format until
    /// the GIF is made (Tim, 2026-11-23): the result then names the recording, with no clipboard time.
    static func finish(_ recording: Recorder.Recording, config: Config) async throws -> RecordingResult {
        var url = recording.url
        var saveFailure: String?
        var copied: ContinuousClock.Instant?
        if config.format == .mp4 {
            let handout = try await handOut(source: recording.url, output: Output(format: .mp4, speed: config.speed),
                                            recordedFPS: recording.fps, saveFolder: config.saveFolderURL, temporary: !config.save)
            url = handout.url
            saveFailure = handout.saveFailure
            if handout.copied { copied = .now }
        }
        return RecordingResult(
            path: url.path,
            sourcePath: recording.url.path,
            format: "mp4",
            speed: config.format == .gif ? 1 : config.speed.rawValue,
            codec: recording.codec == .hevc ? "hevc" : "h264",
            pixelWidth: recording.pixelWidth,
            pixelHeight: recording.pixelHeight,
            requestedFPS: recording.fps,
            stopToFileMilliseconds: milliseconds(recording.fileReady - recording.stopped),
            stopToClipboardMilliseconds: copied.map { milliseconds($0 - recording.stopped) },
            saveFailure: saveFailure)
    }

    /// Fills in the clip's length, frames and size, read from the file.
    static func inspect(_ result: RecordingResult) async -> RecordingResult {
        var result = result
        guard let facts = try? await ClipInspector.facts(for: URL(fileURLWithPath: result.path)) else { return result }
        result.durationSeconds = facts.durationSeconds
        result.frameCount = facts.frameCount
        result.fileBytes = facts.fileBytes
        result.averageFPS = facts.durationSeconds > 0 ? Double(facts.frameCount) / facts.durationSeconds : nil
        return result
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
