import AVFoundation
import CoreVideo
import Foundation

/// The Smaller levers: fewer frames and half size, for an MP4 or a GIF, and a GIF's quality, which Target size lowers last.
public struct Smaller: Equatable, Sendable {
    /// Converts a size entered in decimal megabytes to a positive byte count.
    public static func targetBytes(megabytes text: String) -> Int? {
        guard let megabytes = Double(text) else { return nil }
        let bytes = megabytes * 1_000_000
        guard bytes >= 1, bytes < Double(Int.max) else { return nil }
        return Int(bytes)
    }

    /// GIF stores each frame's delay in hundredths of a second, so two hundredths, 50 fps, is the highest rate it stores
    /// exactly. NewKap caps GIFs at 50 fps for the same reason.
    public static let maximumFPS = 50
    /// gifski's default.
    public static let fullQuality = 90

    /// Fewer frames: the clip's own rate, or a lower one.
    public enum Frames: Int, CaseIterable, Codable, Sendable {
        case native = 0, thirty = 30, twenty = 20, fifteen = 15, ten = 10

        public var label: String { self == .native ? "All" : "\(rawValue) fps" }
    }

    public var frames: Frames = .native
    /// Half the width and height: about a quarter of the pixels.
    public var halfSize = false
    /// gifski's quality, 1 to 100. Only Target size changes it.
    public var quality = Smaller.fullQuality

    public init(frames: Frames = .native, halfSize: Bool = false, quality: Int = Smaller.fullQuality) {
        self.frames = frames
        self.halfSize = halfSize
        self.quality = quality
    }

    /// A GIF's frame rate for a clip recorded at `clipFPS`, after any speed change.
    public func fps(clipFPS: Double) -> Int {
        let native = min(Self.maximumFPS, max(1, Int(clipFPS.rounded())))
        return frames == .native ? native : min(frames.rawValue, native)
    }

    /// An MP4's highest frame rate, or nil to keep every frame.
    public var mp4FPS: Int? { frames == .native ? nil : frames.rawValue }

    /// Whether an MP4 has to be re-encoded for these levers.
    public var changesMP4: Bool { frames != .native || halfSize }

    /// Words for the levers away from their defaults, such as "15 fps, half size".
    public var summary: String {
        [frames == .native ? nil : "\(frames.rawValue) fps", halfSize ? "half size" : nil, quality < Self.fullQuality ? "quality \(quality)" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The rungs Target size steps down from here (Tim, 2026-11-14: frame rate first, then size, then GIF quality).
    public func ladder(gif: Bool) -> [Smaller] {
        var rungs = [self]
        var rung = self
        for frames in Frames.allCases where frames != .native && (rung.frames == .native || frames.rawValue < rung.frames.rawValue) {
            rung.frames = frames
            rungs.append(rung)
        }
        if !rung.halfSize {
            rung.halfSize = true
            rungs.append(rung)
        }
        guard gif else { return rungs }
        for quality in [80, 70, 60, 50, 40] where quality < rung.quality {
            rung.quality = quality
            rungs.append(rung)
        }
        return rungs
    }
}

/// Makes a GIF from a clip with gifski, run as a separate program (plan question 9). The clip's frames are decoded here,
/// taken once per tick of the GIF's frame rate, and streamed to gifski as YUV4MPEG2 with full 4:4:4 colour, so no colour
/// is lost to subsampling on the way.
public enum GIFMaker {
    public enum GIFError: LocalizedError {
        case noVideo
        case unreadable(String)
        case gifskiFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideo: "The clip has no video."
            case .unreadable(let detail): "The clip couldn't be read: \(detail)"
            case .gifskiFailed(let detail): "The GIF couldn't be made: \(detail)"
            }
        }
    }

    /// The times at which to take a frame: one per tick of `fps` over `duration`, at least one.
    public static func ticks(duration: Double, fps: Int) -> [Double] {
        let count = max(1, Int((duration * Double(fps)).rounded(.toNearestOrAwayFromZero)))
        return (0..<count).map { Double($0) / Double(fps) }
    }

    /// Writes the GIF to `gif`. `clipFPS` is the rate the clip was recorded at, after any speed change; `progress` runs
    /// from 0 to 1 as frames are handed over, and the call returns when gifski has written the file.
    public static func make(from clip: URL, to gif: URL, options: Smaller, clipFPS: Double, gifski: URL,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: clip)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GIFError.noVideo }
        let fps = options.fps(clipFPS: clipFPS)
        let ticks = ticks(duration: duration, fps: fps)
        let work = Task.detached(priority: .userInitiated) {
            try encode(asset: asset, track: track, runs: [ticks], fps: fps, options: options, to: gif, gifski: gifski, progress: progress)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// About how many bytes the GIF of `source` would be: the kept part, `trim` in seconds of the recording, played at
    /// `speed`. A clip of up to 12 frames is made in full. A longer one is made at about 400 pixels wide, which keeps
    /// gifski's own handling of what changes from frame to frame; its frames after the first are scaled up by how much
    /// more a run of eight frames costs at full size, the run where a scan of the clip (`ClipScan`) finds the most
    /// change. The first frame is made at full size. On real recordings it lands within about a quarter of the GIF.
    public static func estimate(source: URL, trim: ClosedRange<Double>?, speed: Double, options: Smaller, recordedFPS: Double,
                                gifski: URL) async throws -> Int {
        let asset = AVURLAsset(url: source)
        let length = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GIFError.noVideo }
        let trackStart = try await track.load(.timeRange).start.seconds
        let kept = trim ?? 0...length
        let fps = options.fps(clipFPS: recordedFPS * speed)
        let count = ticks(duration: (kept.upperBound - kept.lowerBound) / speed, fps: fps).count
        let time = { (tick: Int) in kept.lowerBound + Double(tick) / Double(fps) * speed }
        let trackSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = trackSize.applying(transform)
        let natural = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let scan = count > 12 ? try await ClipScan.cached(source) : nil
        let work = Task.detached(priority: .userInitiated) { () throws -> Int in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GIFMachine-estimate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            func bytes(_ times: [Double], _ name: String) throws -> Int {
                let gif = folder.appendingPathComponent(name)
                try encode(asset: asset, track: track, runs: [times], windowed: true, trackStart: trackStart, fps: fps, options: options,
                           to: gif, gifski: gifski)
                return try size(of: gif)
            }
            guard let scan else { return try bytes((0..<count).map(time), "whole.gif") }
            // The whole GIF at about 400 pixels wide, then its frames after the first scaled up by how much more a run
            // of the same frames costs at full size. The first frame is made at full size.
            let divisor = max(2, (natural.width * (options.halfSize ? 0.5 : 1) / 400).rounded(.up))
            let proxySize = CGSize(width: max(2, (natural.width / divisor / 2).rounded() * 2), height: max(2, (natural.height / divisor / 2).rounded() * 2))
            var proxyOptions = options
            proxyOptions.halfSize = false
            func proxyBytes(_ times: [Double], _ name: String) throws -> Int {
                let gif = folder.appendingPathComponent(name)
                try encode(asset: asset, track: track, runs: [times], windowed: true, trackStart: trackStart, decodeSize: proxySize, fps: fps,
                           options: proxyOptions, to: gif, gifski: gifski)
                return try size(of: gif)
            }
            let all = (0..<count).map(time)
            let proxyAll = try proxyBytes(all, "proxy-all.gif")
            let proxyFirst = try proxyBytes([time(0)], "proxy-first.gif")
            let first = try bytes([time(0)], "first.gif")
            // The run of eight ticks where the most changes, so the ratio is measured on frames that cost something.
            let frames = (0..<count).map { scan.index(at: time($0)) }
            let changes = [0.0] + (1..<count).map { scan.changed(from: frames[$0 - 1], to: frames[$0]) }
            let run = 8
            var best = 0, most = -1.0
            for start in stride(from: 0, through: count - run, by: max(1, run / 2)) {
                let sum = changes[(start + 1)..<(start + run)].reduce(0, +)
                if sum > most { (best, most) = (start, sum) }
            }
            let runTimes = (best..<best + run).map(time)
            let fullRun = try bytes(runTimes, "run.gif") - (try bytes([runTimes[0]], "run-first.gif"))
            let proxyRun = try proxyBytes(runTimes, "proxy-run.gif") - (try proxyBytes([runTimes[0]], "proxy-run-first.gif"))
            let ratio = proxyRun > 2_000 ? Double(fullRun) / Double(proxyRun) : Double(first) / Double(max(1, proxyFirst))
            return first + Int(Double(max(0, proxyAll - proxyFirst)) * ratio)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Hands gifski the frame on screen at each time of each run, in seconds from the clip's start, in order. Each run
    /// gets its own reader; `windowed` limits it to the run's times, so a sample late in a long recording doesn't decode
    /// everything before it, and measures times from `trackStart`. Otherwise times are measured from the first frame.
    /// `decodeSize` has the decoder scale each frame to that size first.
    private static func encode(asset: AVURLAsset, track: AVAssetTrack, runs: [[Double]], windowed: Bool = false, trackStart: Double = 0,
                               decodeSize: CGSize? = nil, fps: Int, options: Smaller, to gif: URL, gifski: URL,
                               progress: @Sendable (Double) -> Void = { _ in }) throws {
        let total = runs.reduce(0) { $0 + $1.count }
        var pipe: GifskiPipe?
        var planes: YUVPlanes?
        var done = 0
        do {
            for times in runs {
                guard let firstTime = times.first, let lastTime = times.last else { continue }
                let reader: AVAssetReader
                do { reader = try AVAssetReader(asset: asset) } catch { throw GIFError.unreadable(error.localizedDescription) }
                var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                if let decodeSize {
                    settings[kCVPixelBufferWidthKey as String] = Int(decodeSize.width)
                    settings[kCVPixelBufferHeightKey as String] = Int(decodeSize.height)
                }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                if windowed {
                    reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, trackStart + firstTime - 0.3), preferredTimescale: 600),
                                                   end: CMTime(seconds: trackStart + lastTime + 0.3, preferredTimescale: 600))
                }
                reader.add(output)
                defer { reader.cancelReading() }
                guard reader.startReading(), var current = output.copyNextSampleBuffer(),
                      let firstPixels = CMSampleBufferGetImageBuffer(current)
                else { throw GIFError.unreadable(reader.error?.localizedDescription ?? "no frames") }
                let origin = windowed ? trackStart : CMSampleBufferGetPresentationTimeStamp(current).seconds
                if pipe == nil {
                    let width = CVPixelBufferGetWidth(firstPixels), height = CVPixelBufferGetHeight(firstPixels)
                    pipe = try GifskiPipe(gifski: gifski, width: width, height: height, fps: fps, options: options, to: gif)
                    planes = YUVPlanes(width: width, height: height)
                }
                var next = output.copyNextSampleBuffer()
                for tick in times {
                    try Task.checkCancellation()
                    // The frame on screen at this tick: the latest one shown at or before it.
                    while let candidate = next, CMSampleBufferGetPresentationTimeStamp(candidate).seconds - origin <= tick + 0.0005 {
                        current = candidate
                        next = output.copyNextSampleBuffer()
                    }
                    if let pixels = CMSampleBufferGetImageBuffer(current) { planes?.fill(from: pixels) }
                    if let frame = planes?.data { try pipe?.write(frame) }
                    done += 1
                    progress(Double(done) / Double(total))
                }
            }
        } catch {
            pipe?.abandon()
            throw error
        }
        try pipe?.finish()
    }
}

/// How much of the picture changes between any two frames of a recording, from a grid of 96 × 60 cells: each frame's
/// cells are hashed from a sample of the luma plane, every third pixel across and down. Made once per recording.
public final class ClipScan: Sendable {
    /// Each frame's time, in seconds from the first frame.
    public let times: [Double]
    private let hashes: [UInt32]
    static let columns = 96, rows = 60

    private init(times: [Double], hashes: [UInt32]) {
        self.times = times
        self.hashes = hashes
    }

    nonisolated(unsafe) private static var lastScan: (source: URL, scan: ClipScan)?
    private static let lock = NSLock()

    /// The scan of `source`, made on first use.
    public static func cached(_ source: URL) async throws -> ClipScan {
        if let cached = lock.withLock({ lastScan }), cached.source == source { return cached.scan }
        let work = Task.detached(priority: .userInitiated) { try await make(source) }
        let scan = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        lock.withLock { lastScan = (source, scan) }
        return scan
    }

    private static func make(_ source: URL) async throws -> ClipScan {
        let asset = AVURLAsset(url: source)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GIFMaker.GIFError.noVideo }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw GIFMaker.GIFError.unreadable(reader.error?.localizedDescription ?? "unreadable") }
        var times: [Double] = []
        var hashes: [UInt32] = []
        var origin: Double?
        let cells = columns * rows
        var row = [UInt32](repeating: 0, count: cells)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let at = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            origin = origin ?? at
            times.append(at - (origin ?? at))
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self) else {
                hashes.append(contentsOf: row)
                continue
            }
            let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            for index in 0..<cells { row[index] = 2_166_136_261 }
            var y = 0
            while y < height {
                let cellRow = min(rows - 1, y * rows / height) * columns
                let line = base + y * rowBytes
                var x = 0
                while x < width {
                    let cell = cellRow + min(columns - 1, x * columns / width)
                    row[cell] = (row[cell] ^ UInt32(line[x])) &* 16_777_619
                    x += 3
                }
                y += 3
            }
            hashes.append(contentsOf: row)
        }
        guard reader.status != .failed else { throw GIFMaker.GIFError.unreadable(reader.error?.localizedDescription ?? "unreadable") }
        return ClipScan(times: times, hashes: hashes)
    }

    /// The frame on screen at `time`: the latest at or before it.
    public func index(at time: Double) -> Int {
        var low = 0, high = times.count - 1
        guard high > 0 else { return 0 }
        while low < high {
            let middle = (low + high + 1) / 2
            if times[middle] <= time + 0.0005 { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The share of cells that differ between two frames, 0 to 1.
    public func changed(from first: Int, to second: Int) -> Double {
        guard first != second else { return 0 }
        let cells = Self.columns * Self.rows
        var differing = 0
        for cell in 0..<cells where hashes[first * cells + cell] != hashes[second * cells + cell] { differing += 1 }
        return Double(differing) / Double(cells)
    }
}

/// gifski reading YUV4MPEG2 frames on its standard input.
private final class GifskiPipe {
    private let process = Process()
    private let input = Pipe()
    private let errors = Pipe()
    private let gif: URL

    init(gifski: URL, width: Int, height: Int, fps: Int, options: Smaller, to gif: URL) throws {
        self.gif = gif
        try? FileManager.default.removeItem(at: gif)
        process.executableURL = gifski
        process.arguments = ["--fps", "\(fps)", "--width", "\(options.halfSize ? max(1, width / 2) : width)", "--quality", "\(options.quality)",
                             "--y4m-color-override", "bt709", "--quiet", "--output", gif.path, "-"]
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // A write after gifski has quit fails with an error rather than a SIGPIPE that would end the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try input.fileHandleForWriting.write(contentsOf: Data("YUV4MPEG2 W\(width) H\(height) F\(fps):1 Ip A1:1 C444 XCOLORRANGE=FULL\n".utf8))
    }

    func write(_ frame: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: Data("FRAME\n".utf8))
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func abandon() {
        try? input.fileHandleForWriting.close()
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: gif)
    }

    func finish() throws {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(at: gif)
            throw GIFMaker.GIFError.gifskiFailed(message.isEmpty ? "gifski exited with status \(process.terminationStatus)" : message)
        }
    }
}

/// One frame as YUV4MPEG2 C444 planes, full range, with the BT.709 matrix gifski is told to undo.
struct YUVPlanes {
    let width: Int
    let height: Int
    private(set) var data: Data

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        data = Data(count: width * height * 3)
    }

    /// Converts a BGRA pixel buffer of this size.
    mutating func fill(from pixels: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self),
              CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let (width, height) = (self.width, self.height)
        data.withUnsafeMutableBytes { raw in
            guard let out = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            Self.convert(base, rowBytes: rowBytes, width: width, height: height, into: out)
        }
    }

    /// Fixed-point BT.709, full range: Y = 0.2126 R + 0.7152 G + 0.0722 B, and Cb and Cr centred on 128.
    static func convert(_ bgra: UnsafePointer<UInt8>, rowBytes: Int, width: Int, height: Int, into out: UnsafeMutablePointer<UInt8>) {
        let plane = width * height
        let yPlane = out, cbPlane = out + plane, crPlane = out + 2 * plane
        let half = 32768, center = 128 << 16
        for row in 0..<height {
            let source = bgra + row * rowBytes
            let offset = row * width
            for column in 0..<width {
                let b = Int(source[column * 4]), g = Int(source[column * 4 + 1]), r = Int(source[column * 4 + 2])
                let y = (13933 * r + 46871 * g + 4732 * b + half) >> 16
                let cb = (-7510 * r - 25258 * g + 32768 * b + center + half) >> 16
                let cr = (32768 * r - 29766 * g - 3002 * b + center + half) >> 16
                yPlane[offset + column] = UInt8(clamping: y)
                cbPlane[offset + column] = UInt8(clamping: cb)
                crPlane[offset + column] = UInt8(clamping: cr)
            }
        }
    }
}
