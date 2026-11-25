import AppKit
import AVFoundation
import GIFMachineCore
import SwiftUI

/// One recording's clip, shared by the preview window and the editor: the choices, the player showing them, the size
/// estimate, and Copy. Every choice shows in the player at once (the speed as the play rate, the trim as the loop, a GIF's
/// frame rate and size on the picture); nothing is made until Copy, except the format and speed the settings ask for,
/// which start at Stop. No control locks while a clip is made; changing a choice stops it. Each copy is a new clipboard
/// entry and the clips copied before it stay, so a clipboard history can paste them; copying a choice made before puts
/// that clip back without making it again.
@MainActor
final class ClipModel: ObservableObject {
    let source: URL
    let saveFolder: URL?
    let pixelSize: CGSize
    let recordedFPS: Int
    let plays: Bool
    /// Saving is off: closing the clip's last window discards the recording and the clips made from it.
    let temporary: Bool
    let player = AVQueuePlayer()
    /// Where the player is, for the editor's timeline; kept apart so the preview window doesn't redraw 30 times a second.
    let playhead = Playhead()
    /// The clip on the clipboard, and what it was made as.
    @Published private(set) var output: URL
    @Published private(set) var made: Delivery.Output
    @Published private(set) var outputBytes: Int?
    /// The clipboard still holds `output`: nothing else has been copied since.
    @Published private(set) var copied: Bool
    /// What Copy makes.
    @Published private(set) var choice: Delivery.Output
    /// 0 to 1 while a clip is made; only a GIF reports progress.
    @Published private(set) var making: Double?
    /// Target size is looking for the settings that fit.
    @Published private(set) var fitting = false
    /// What Target size settled on for the clip on the clipboard.
    @Published private(set) var fitted: Delivery.Fitted?
    @Published private(set) var failure: String?
    @Published private(set) var saveFailure: String?
    let captureNotice: String?
    /// A clip being made was stopped by a change.
    @Published private(set) var stopped = false
    /// About how big the chosen clip would be, without Target size.
    @Published private(set) var estimate: Int?
    @Published private(set) var estimating = false
    /// The recording's length in seconds, once read.
    @Published private(set) var duration: Double = 0
    /// The trim while a handle is dragged, before it's applied.
    @Published private(set) var draggedTrim: ClosedRange<Double>?
    @Published var pointerInside = false
    var onHandout: (URL, Delivery.Output) -> Void = { _, _ in }
    /// A GIF's making from 0 to 1, then nil.
    var onProgress: (Double?) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onOpenEditor: (() -> Void)?
    private var looper: AVPlayerLooper?
    private var composition: AVMutableVideoComposition?
    private var job: (id: UUID, task: Task<Void, Never>)?
    private var estimateJob: Task<Void, Never>?
    private var estimated: Delivery.Output?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    /// The clipboard's change count after this clip last went on it.
    private var copiedCount: Int?
    private var clipboardWatch: Timer?
    /// The clips handed out so far, the latest last.
    private var clips: [(output: Delivery.Output, url: URL, fitted: Delivery.Fitted?)] = []
    private(set) var discarded = false

    /// `made` is what `output` already is; `choice` is what the settings ask for, made at once by `makeIfNeeded`.
    /// `copied` says the clipboard holds `output` now; `handedOut`, that it was copied at all.
    init(source: URL, output: URL, made: Delivery.Output, choice: Delivery.Output, recordedFPS: Int, saveFolder: URL?,
         saveFailure: String?, pixelSize: CGSize, plays: Bool = true, duration: Double = 0, temporary: Bool = false,
         copied: Bool = true, handedOut: Bool = true, captureNotice: String? = nil) {
        self.source = source
        self.temporary = temporary
        self.copied = copied
        copiedCount = copied ? Clipboard.count : nil
        if handedOut { clips = [(made, output, nil)] }
        self.output = output
        self.made = made
        self.choice = choice
        self.recordedFPS = recordedFPS
        self.saveFolder = saveFolder
        self.saveFailure = saveFailure
        self.captureNotice = captureNotice
        self.pixelSize = pixelSize
        self.plays = plays
        self.duration = duration
        outputBytes = Self.bytes(of: output)
        guard plays else { return }
        watchClipboard()
        player.isMuted = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.draggedTrim == nil, !self.playhead.scrubbing else { return }
                self.playhead.time = time.seconds
            }
        }
        statusObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.playhead.playing = playing }
        }
        loop()
        Task {
            let asset = AVURLAsset(url: source)
            self.duration = (try? await asset.load(.duration).seconds) ?? 0
            composition = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            if self.choice.format == .gif { loop() }
            refreshEstimate()
        }
    }

    // MARK: The player

    /// Plays the kept part on a loop at the chosen speed; for a GIF, at its frame rate and size.
    private func loop() {
        guard plays else { return }
        // A change while paused, as from the editor's keys, leaves it paused.
        let resumes = looper == nil || player.rate != 0
        looper?.disableLooping()
        player.removeAllItems()
        let item = AVPlayerItem(url: source)
        if choice.format == .gif, let gif = composition?.mutableCopy() as? AVMutableVideoComposition {
            let fps = choice.smaller.fps(clipFPS: Double(recordedFPS) * choice.speed.rawValue)
            // In the recording's own time: at ½× each GIF frame covers half as much of it.
            gif.frameDuration = CMTime(seconds: choice.speed.rawValue / Double(fps), preferredTimescale: 60_000)
            gif.renderScale = choice.smaller.halfSize ? 0.5 : 1
            item.videoComposition = gif
        }
        let range = choice.trim.map {
            CMTimeRange(start: CMTime(seconds: $0.lowerBound, preferredTimescale: 600), end: CMTime(seconds: $0.upperBound, preferredTimescale: 600))
        } ?? .invalid
        looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
        player.defaultRate = Float(choice.speed.rawValue)
        if resumes { player.play() }
    }

    /// Starts the loop again after `stop`, for a window that takes the clip over.
    func start() {
        guard plays, !discarded else { return }
        watchClipboard()
        if looper == nil { loop() }
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        clipboardWatch?.invalidate()
        clipboardWatch = nil
    }

    func togglePlay() {
        guard plays else { return }
        if looper == nil { loop(); return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    /// Moves the playhead while the timeline is dragged; `endScrub` plays on from there if it was playing.
    func scrub(to time: Double) {
        guard plays else { return }
        if !playhead.scrubbing {
            playhead.scrubbing = true
            playhead.resumes = player.timeControlStatus != .paused
            player.pause()
        }
        let kept = choice.trim ?? 0...max(duration, 0.001)
        let clamped = min(max(time, kept.lowerBound), kept.upperBound)
        playhead.time = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func endScrub() {
        guard playhead.scrubbing else { return }
        playhead.scrubbing = false
        if playhead.resumes { player.play() }
    }

    /// One frame of the recording back or forward, paused.
    func step(_ frames: Int) {
        player.pause()
        scrub(to: playhead.time + Double(frames) / Double(max(1, recordedFPS)))
        playhead.scrubbing = false
    }

    // MARK: Trim

    /// The part a trim bar shows: the dragged trim, the chosen one, or all of it.
    var shownTrim: ClosedRange<Double> { draggedTrim ?? choice.trim ?? 0...max(duration, 0.001) }

    /// While a handle moves, the frame at it shows; letting go keeps that part.
    func drag(_ range: ClosedRange<Double>, showing time: Double) {
        draggedTrim = range
        playhead.time = time
        player.pause()
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func endDrag() {
        guard let range = draggedTrim else { return }
        draggedTrim = nil
        setTrim(range)
        if plays { player.play() }
    }

    /// Keeps from the playhead to the trim's end, or from its start to the playhead.
    func trimStart() { setTrim(min(playhead.time, shownTrim.upperBound - 0.2)...shownTrim.upperBound) }
    func trimEnd() { setTrim(shownTrim.lowerBound...max(playhead.time, shownTrim.lowerBound + 0.2)) }

    private func setTrim(_ range: ClosedRange<Double>) {
        let range = max(0, range.lowerBound)...min(max(duration, range.lowerBound + 0.001), range.upperBound)
        let whole = range.lowerBound <= 0.02 && range.upperBound >= duration - 0.02
        change(replay: true) { $0.trim = whole ? nil : range }
    }

    func resetTrim() { change(replay: true) { $0.trim = nil } }

    /// Fits the clip in `box` points.
    func videoSize(in box: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return CGSize(width: box.width, height: box.width * 0.625) }
        let scale = min(box.width / pixelSize.width, box.height / pixelSize.height)
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }

    // MARK: Choices

    func choose(_ format: Config.Format) { change(replay: true) { $0.format = format } }

    func choose(_ speed: Config.Speed) {
        change(replay: choice.format == .gif) { $0.speed = speed }
        player.defaultRate = Float(speed.rawValue)
        if player.rate != 0 { player.rate = Float(speed.rawValue) }
    }

    func choose(_ frames: Smaller.Frames) { change(replay: true) { $0.smaller.frames = frames } }

    func toggleHalfSize() { change(replay: true) { $0.smaller.halfSize.toggle() } }

    /// A file-size limit in bytes, or nil for none.
    func chooseTarget(_ bytes: Int?) { change(replay: false) { $0.target = bytes } }

    private func change(replay: Bool, _ edit: (inout Delivery.Output) -> Void) {
        var next = choice
        edit(&next)
        guard next != choice else { return }
        choice = next
        failure = nil
        if let job {
            job.task.cancel()
            self.job = nil
            making = nil
            fitting = false
            stopped = true
            onProgress(nil)
        }
        if replay { loop() }
        refreshEstimate()
    }

    // MARK: Estimate

    /// Estimates the chosen clip, without Target size, a moment after the last change. A GIF's estimate makes small GIFs,
    /// so it waits while the chosen GIF is being made: that GIF's size comes soon, and the estimate would slow it down.
    private func refreshEstimate() {
        guard plays, duration > 0 else { return }
        var wanted = choice
        wanted.target = nil
        if wanted.format == .gif, making != nil {
            estimateJob?.cancel()
            estimated = nil
            estimate = nil
            estimating = false
            return
        }
        guard wanted != estimated else { return }
        estimated = wanted
        estimateJob?.cancel()
        estimating = true
        estimateJob = Task { [source, recordedFPS] in
            if wanted.format == .gif { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            let bytes = try? await Delivery.estimate(source: source, output: wanted, recordedFPS: recordedFPS)
            guard !Task.isCancelled else { return }
            estimate = bytes
            estimating = false
        }
    }

    // MARK: Copy

    /// The clipboard holds what's chosen.
    var isCopied: Bool { made == choice && making == nil && copied }

    /// Choices the clipboard doesn't have yet, or a clip being made: the preview window stays open for them.
    var pending: Bool { !isCopied }

    /// Makes the settings' clip when it isn't what Stop already copied.
    func makeIfNeeded() {
        if choice != made { copy() }
    }

    /// Makes the chosen clip, puts it on the clipboard and in the save folder; `saveAs` also copies it there. A clip
    /// already made goes back on the clipboard unless it's there now.
    func copy(saveAs destination: URL? = nil) {
        if making == nil, let earlier = earlierClip {
            if !isCopied { publish(earlier) }
            if let destination { save(earlierClip?.url ?? earlier.url, to: destination) }
            return
        }
        guard making == nil, !discarded else { return }
        let wanted = choice
        failure = nil
        stopped = false
        making = 0
        refreshEstimate()
        let id = UUID()
        let task = Task { [self] in
            do {
                let handout = try await Delivery.handOut(source: source, output: wanted, recordedFPS: recordedFPS, saveFolder: saveFolder,
                                                         temporary: temporary) { [weak self] fraction in
                    Task { @MainActor [weak self] in self?.progressed(fraction, job: id) }
                } fitting: { [weak self] in
                    Task { @MainActor [weak self] in if self?.job?.id == id { self?.fitting = true } }
                }
                // A stopped clip can finish after all; it's on the clipboard then, so it's what's made.
                remember(wanted, handout.url, handout.fitted)
                output = handout.url
                made = wanted
                outputBytes = Self.bytes(of: handout.url)
                saveFailure = handout.saveFailure
                fitted = handout.fitted
                if handout.copied { copiedCount = Clipboard.count }
                refreshCopied()
                if handout.copied || saveFolder != nil { onHandout(handout.url, wanted) }
                if job?.id == id, let destination { save(handout.url, to: destination) }
            } catch {
                if job?.id == id, !(error is CancellationError) { failure = error.localizedDescription }
            }
            if job?.id == id {
                job = nil
                making = nil
                fitting = false
                onProgress(nil)
                if made != choice { refreshEstimate() }
            }
        }
        job = (id, task)
    }

    /// The clip already made for the choice, while its file is there.
    private var earlierClip: (output: Delivery.Output, url: URL, fitted: Delivery.Fitted?)? {
        clips.last { $0.output == choice && FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func remember(_ output: Delivery.Output, _ url: URL, _ fitted: Delivery.Fitted?) {
        clips.removeAll { $0.output == output }
        clips.append((output, url, fitted))
    }

    /// Puts a clip made before back on the clipboard, as a new entry.
    private func publish(_ clip: (output: Delivery.Output, url: URL, fitted: Delivery.Fitted?)) {
        do {
            let url = try Clipboard.publish(clip.url, temporary: temporary, source: source)
            remember(clip.output, url, clip.fitted)
            output = url
            made = clip.output
            fitted = clip.fitted
            outputBytes = Self.bytes(of: url)
            failure = nil
            stopped = false
            copiedCount = Clipboard.count
            copied = true
            onHandout(url, made)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Notices something else being copied. Reads only the clipboard's change count.
    private func watchClipboard() {
        guard clipboardWatch == nil else { return }
        refreshCopied()
        clipboardWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCopied() }
        }
    }

    private func refreshCopied() {
        let now = copiedCount == Clipboard.count
        if now != copied { copied = now }
    }

    /// Writes a copy over `destination` in one step, so a failed save leaves what was there. Saving the clip onto its own
    /// file does nothing.
    private func save(_ file: URL, to destination: URL) {
        do {
            try Paths.replace(destination, withCopyOf: file)
        } catch {
            failure = "Not saved to \(Paths.display(destination)): \(error.localizedDescription)"
        }
    }

    private func progressed(_ fraction: Double, job id: UUID) {
        guard job?.id == id else { return }
        fitting = false
        guard choice.format == .gif else { return }
        making = fraction
        onProgress(fraction)
    }

    /// With saving off, the clip's last window closed: what's being made stops, and the recording and the clips made from
    /// it are deleted. The clipboard's copies stay.
    func discard() {
        guard temporary, !discarded else { return }
        discarded = true
        job?.task.cancel()
        job = nil
        making = nil
        fitting = false
        onProgress(nil)
        estimateJob?.cancel()
        stop()
        player.removeAllItems()
        Paths.discard(source)
    }

    // MARK: Copy smaller

    /// The size Copy Smaller aims under.
    static let smallerTarget = 10_000_000

    enum SizeSwitch { case smaller, fullSize }

    /// The preview's second copy action, for an MP4: a smaller copy when the clip is over 10 MB, then back to full size.
    var sizeSwitch: SizeSwitch? {
        guard choice.format == .mp4 else { return nil }
        if choice.target != nil { return .fullSize }
        guard let estimate, !estimating, estimate > Self.smallerTarget else { return nil }
        return .smaller
    }

    func copySmaller() {
        chooseTarget(Self.smallerTarget)
        copy()
    }

    func copyFullSize() {
        chooseTarget(nil)
        copy()
    }

    var sizeSwitchLabel: String {
        switch sizeSwitch {
        case .smaller: "Copy smaller MP4 · under \(Self.megabytes(Self.smallerTarget))"
        case .fullSize: "Copy full size" + (estimate.map { " · about \(Self.megabytes($0))" } ?? "")
        case nil: ""
        }
    }

    func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting([output]) }

    // MARK: Words

    var formatName: String { choice.format == .gif ? "GIF" : "MP4" }

    /// The file Copy makes.
    var fileName: String {
        let base = source.deletingPathExtension().lastPathComponent
        let suffix = (choice.speed == .normal ? "" : " \(choice.speed.fileSuffix)") + (choice.trim == nil ? "" : " trimmed")
        return "\(base)\(suffix).\(choice.format.rawValue)"
    }

    var keptSeconds: Double { (choice.trim.map { $0.upperBound - $0.lowerBound } ?? duration) / choice.speed.rawValue }

    var length: String { String(format: "%.1f s", keptSeconds) }

    static func megabytes(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    var copyLabel: String {
        if fitting, let target = choice.target { return "Fitting under \(Self.megabytes(target))…" }
        if let making { return choice.format == .gif && making > 0 ? "Making GIF… \(Int(making * 100))%" : "Making \(formatName)…" }
        if isCopied { return "Copied" + (outputBytes.map { " · " + Self.megabytes($0) } ?? "") }
        // Made before, and not on the clipboard now.
        if let earlier = earlierClip, let bytes = Self.bytes(of: earlier.url) {
            return "Copy \(formatName) · \(length) · \(Self.megabytes(bytes))"
        }
        let size = choice.target.map { " · under " + Self.megabytes($0) }
            ?? (estimating ? nil : estimate.map { " · about " + Self.megabytes($0) })
        return "Copy \(formatName)" + (duration > 0 ? " · \(length)" : "") + (size ?? "")
    }

    var copyHelp: String {
        if temporary { return "Copies the clip. Closing the last clip window discards the recording. Your clipboard copy stays ready to paste." }
        guard let saveFolder else { return "Copies the clip" }
        return "Copies the clip and saves it to \(saveFolder.lastPathComponent)"
    }

    /// The size line: the copied file's size, with what Target size chose; or the estimate.
    var sizeLine: String {
        if isCopied, let bytes = outputBytes {
            guard let fitted, let target = made.target else { return Self.megabytes(bytes) }
            let settings = [fitted.smaller.summary, fitted.bitRate.map { String(format: "%.1f Mbit/s", $0 / 1_000_000) }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            return fitted.fits
                ? "\(Self.megabytes(bytes)), under \(Self.megabytes(target))" + (settings.isEmpty ? "" : " at \(settings)")
                : "\(Self.megabytes(bytes)): over \(Self.megabytes(target)) even at \(settings)"
        }
        if estimating { return "Estimating…" }
        guard let estimate else { return "" }
        if let target = choice.target, estimate > target {
            return "About \(Self.megabytes(estimate)); Target size brings it under \(Self.megabytes(target))"
        }
        return "About \(Self.megabytes(estimate))"
    }

    /// A line under Copy, only when something went wrong or was stopped.
    var note: String? {
        if let failure { return "\(formatName) failed: \(failure)" }
        if stopped, making == nil, !isCopied { return "Stopped · press Copy again" }
        if isCopied, let fitted, !fitted.fits, let target = made.target {
            return "Over \(Self.megabytes(target)) even at the smallest settings"
        }
        if isCopied, let saveFailure { return saveFailure }
        return captureNotice
    }

    private static func bytes(of url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    }
}

/// The player's position, in seconds of the recording, and whether it plays.
@MainActor
final class Playhead: ObservableObject {
    @Published var time: Double = 0
    @Published var playing = false
    var scrubbing = false
    var resumes = false
}
