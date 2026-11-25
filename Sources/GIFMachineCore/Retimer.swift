import AVFoundation
import CoreMedia

/// Makes a copy of a recording that plays at another speed.
///
/// Slowing down keeps every frame and only changes the timestamps, so nothing is re-encoded: a 120 fps recording at ½×
/// plays as 60 fps. Speeding up drops frames that would land closer together than `FrameRate` allows for the clip's size,
/// and re-encodes the rest with H.264.
public enum Retimer {
    public enum RetimeError: LocalizedError {
        case noVideo
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideo: "The recording has no video track."
            case .failed(let message): "The clip could not be made: \(message)"
            }
        }
    }

    /// `destination` must not exist yet. `trim` keeps the part between two times, in seconds from the first frame; the
    /// frame on screen at its start opens the clip. Trimming re-encodes, so the clip can start between key frames.
    /// `fps` keeps at most that many frames a second of the new clip, `halfSize` halves the width and height, and `bitRate`
    /// sets the encoder's average bits a second; each re-encodes.
    public static func retime(_ source: URL, speed: Double, trim: ClosedRange<Double>? = nil, fps: Int? = nil, halfSize: Bool = false,
                              bitRate: Double? = nil, to destination: URL) async throws {
        precondition(speed > 0)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RetimeError.noVideo }
        let (formats, transform, size, dataRate, timeRange) = try await track.load(
            .formatDescriptions, .preferredTransform, .naturalSize, .estimatedDataRate, .timeRange)
        let reencodes = speed > 1 || trim != nil || fps != nil || halfSize || bitRate != nil
        let (width, height) = outputSize(size, halfSize: halfSize)
        var sieve = FrameSieve(speed: speed, fps: fps, width: width, height: height)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: reencodes
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            : nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input: AVAssetWriterInput
        if reencodes {
            var settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResize,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate ?? max(2_000_000, Double(dataRate) * max(1, speed)) * (halfSize ? 0.4 : 1),
                    AVVideoExpectedSourceFrameRateKey: sieve.maximumFPS,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ] as [String: Any],
            ]
            if let colors = formats.first.flatMap(colorProperties) { settings[AVVideoColorPropertiesKey] = colors }
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        } else {
            input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        }
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        writer.add(input)

        guard reader.startReading() else { throw RetimeError.failed(reader.error?.localizedDescription ?? "the recording can't be read") }
        guard writer.startWriting() else { throw RetimeError.failed(writer.error?.localizedDescription ?? "the file can't be written") }
        writer.startSession(atSourceTime: .zero)

        let cut = trim?.lowerBound ?? 0
        /// The last frame before the trim's start, shown at the start when no frame falls on it.
        var held: CMSampleBuffer?
        // Times are measured from the first frame. The reader's times can be offset from the track's time range, so the
        // range only supplies the length. With reordered frames a decode time comes before the first frame's
        // presentation time, so decode times may be negative; the writer accepts that.
        var start: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            // The reader also returns empty marker buffers, such as for an edit list's leading gap.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            var timings = try sample.sampleTimingInfos()
            guard let first = timings.first else { continue }
            let origin = start ?? first.presentationTimeStamp
            start = origin
            if let trim {
                let at = (first.presentationTimeStamp - origin).seconds
                if at < trim.lowerBound - 0.0005 {
                    held = sample
                    continue
                }
                if at > trim.upperBound + 0.0005 { break }
                if let opening = held, at > trim.lowerBound + 0.0005 {
                    // Nothing falls on the start: the frame before it opens the clip, then this one follows.
                    held = nil
                    try await append(opening, at: CMTime(seconds: cut, preferredTimescale: timescale), origin: origin, cut: cut,
                                     speed: speed, to: input, writer: writer)
                    sieve.opened()
                }
                held = nil
            }
            guard sieve.keeps(((first.presentationTimeStamp - origin).seconds - cut) / speed) else { continue }
            if trim != nil {
                try await append(sample, at: first.presentationTimeStamp, origin: origin, cut: cut, speed: speed, to: input, writer: writer)
                continue
            }
            for index in timings.indices {
                timings[index].presentationTimeStamp = scaled(timings[index].presentationTimeStamp, from: origin, speed: speed)
                timings[index].decodeTimeStamp = reencodes ? .invalid : scaled(timings[index].decodeTimeStamp, from: origin, speed: speed)
                timings[index].duration = reencodes ? .invalid : scaledDuration(timings[index].duration, speed: speed)
            }
            var retimed: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: timings.count,
                sampleTimingArray: &timings, sampleBufferOut: &retimed)
            guard status == noErr, let retimed else { throw RetimeError.failed("a frame's timing could not be changed (\(status))") }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard input.append(retimed) else {
                throw RetimeError.failed(writer.error?.localizedDescription ?? "a frame could not be written")
            }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw RetimeError.failed(reader.error?.localizedDescription ?? "the recording stopped reading")
        }
        if let opening = held, let start {
            // The trim fell after the last frame's start: that frame is the whole clip.
            try await append(opening, at: start + CMTime(seconds: cut, preferredTimescale: timescale), origin: start, cut: cut,
                             speed: speed, to: input, writer: writer)
        }
        input.markAsFinished()
        if start != nil {
            let length = trim.map { min($0.upperBound, timeRange.duration.seconds) - $0.lowerBound } ?? timeRange.duration.seconds
            writer.endSession(atSourceTime: CMTime(seconds: max(0.001, length) / speed, preferredTimescale: timescale))
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RetimeError.failed(writer.error?.localizedDescription ?? "the file was not finished")
        }
    }

    /// The times of the recording's frames, in seconds from the first, in the order they show. Read from the file's index,
    /// without decoding. A recording only gets a frame when the screen changes, so these can be far fewer than its length
    /// times its frame rate.
    public static func frameTimes(_ source: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RetimeError.noVideo }
        var times: [Double] = []
        if try await track.load(.canProvideSampleCursors), let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            repeat { times.append(cursor.presentationTimeStamp.seconds) } while cursor.stepInDecodeOrder(byCount: 1) == 1
        } else {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else { throw RetimeError.failed(reader.error?.localizedDescription ?? "the recording can't be read") }
            while let sample = output.copyNextSampleBuffer() {
                times += try sample.sampleTimingInfos().map(\.presentationTimeStamp.seconds)
            }
        }
        times.sort()
        guard let first = times.first else { return [] }
        return times.map { $0 - first }
    }

    /// How many of the frames at `times` (from `frameTimes`) a clip made by `retime` keeps.
    public static func keptFrames(_ times: [Double], size: CGSize, speed: Double, trim: ClosedRange<Double>? = nil, fps: Int? = nil,
                                  halfSize: Bool = false) -> Int {
        let (width, height) = outputSize(size, halfSize: halfSize)
        var sieve = FrameSieve(speed: speed, fps: fps, width: width, height: height)
        let cut = trim?.lowerBound ?? 0
        var held = false
        var kept = 0
        for at in times {
            if let trim {
                if at < trim.lowerBound - 0.0005 {
                    held = true
                    continue
                }
                if at > trim.upperBound + 0.0005 { break }
                if held, at > trim.lowerBound + 0.0005 {
                    kept += 1
                    sieve.opened()
                }
                held = false
                // A frame on the trim's end shows for no time, so the file leaves it out.
                if at >= trim.upperBound - 0.0005 { break }
            }
            if sieve.keeps((at - cut) / speed) { kept += 1 }
        }
        return held ? kept + 1 : kept
    }

    private static func outputSize(_ size: CGSize, halfSize: Bool) -> (width: Int, height: Int) {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        return halfSize ? (max(2, width / 2 / 2 * 2), max(2, height / 2 / 2 * 2)) : (width, height)
    }

    /// Picks the frames a clip keeps, given each one's time in the new clip.
    private struct FrameSieve {
        let maximumFPS: Int
        /// Frames closer together than this are dropped when speeding up. The margin absorbs capture jitter.
        let minimumGap: Double
        /// Fewer frames: a frame is kept when it reaches the next tick of the chosen rate, a quarter period early at most.
        let period: Double?
        var nextTick = 0.0
        var lastKept = -Double.infinity

        init(speed: Double, fps: Int?, width: Int, height: Int) {
            maximumFPS = FrameRate.forRecording(displayMaximum: FrameRate.smallRecordingMaximum, pixelWidth: width, pixelHeight: height)
            minimumGap = speed > 1 ? 0.75 / Double(maximumFPS) : 0
            period = fps.map { 1 / Double(max(1, $0)) }
        }

        /// The frame before a trim's start opens the clip at its start.
        mutating func opened() { lastKept = 0 }

        mutating func keeps(_ presented: Double) -> Bool {
            if minimumGap > 0 {
                guard presented - lastKept >= minimumGap else { return false }
                lastKept = presented
            }
            if let period {
                guard presented + period / 4 >= nextTick else { return false }
                while nextTick <= presented + period / 4 { nextTick += period }
            }
            return true
        }
    }

    /// Appends a decoded frame shown at `presented`, in the recording's time, moved to the trimmed clip's time.
    private static func append(_ sample: CMSampleBuffer, at presented: CMTime, origin: CMTime, cut: Double, speed: Double,
                               to input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let seconds = max(0, ((presented - origin).seconds - cut) / speed)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: timescale),
                                        decodeTimeStamp: .invalid)
        var moved: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timing, sampleBufferOut: &moved)
        guard status == noErr, let moved else { throw RetimeError.failed("a frame's timing could not be changed (\(status))") }
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        guard input.append(moved) else { throw RetimeError.failed(writer.error?.localizedDescription ?? "a frame could not be written") }
    }

    private static let timescale: CMTimeScale = 600_000

    private static func scaled(_ time: CMTime, from origin: CMTime, speed: Double) -> CMTime {
        guard time.isValid else { return time }
        return CMTime(seconds: (time - origin).seconds / speed, preferredTimescale: timescale)
    }

    private static func scaledDuration(_ duration: CMTime, speed: Double) -> CMTime {
        guard duration.isValid, duration.isNumeric else { return duration }
        return CMTime(seconds: duration.seconds / speed, preferredTimescale: timescale)
    }

    /// The source's colour tags, so a re-encoded clip keeps its colours. CoreMedia and AVFoundation use the same strings.
    private static func colorProperties(_ format: CMFormatDescription) -> [String: String]? {
        func value(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        guard let primaries = value(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = value(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = value(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
    }
}
