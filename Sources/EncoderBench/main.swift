import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

// Measures whether the hardware encoders keep up with native-resolution, high-frame-rate recording.
// Frames are synthetic and screen-like (light background, rows of dark text-like runs, a moving block),
// so no Screen Recording permission is needed.
//
// Usage: EncoderBench [seconds] [output directory]

struct BenchCase {
    let codec: AVVideoCodecType
    let width: Int
    let height: Int
    let fps: Int
    var yuvInput = true
    var prioritizeSpeed = false
    var variant: Variant = .standard

    enum Variant: String { case standard, realTime = "real-time", lowLatency = "low-latency", mainProfile = "Main profile" }

    var label: String {
        "\(codec == .h264 ? "H.264" : "HEVC") \(width)x\(height) @\(fps) \(yuvInput ? "420v" : "BGRA")\(prioritizeSpeed ? " speed" : "")\(variant == .standard ? "" : " \(variant.rawValue)")"
    }
}

struct BenchResult: Codable {
    let label: String
    let hardwareRequired: Bool
    let frames: Int
    let seconds: Double
    let achievedFPS: Double
    let keepsUp: Bool
    let fileBytes: Int
    let megabitsPerSecond: Double
    let profileLevel: String
    let error: String?
}

let arguments = Array(CommandLine.arguments.dropFirst())
let clipSeconds = arguments.first.flatMap(Int.init) ?? 4
let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : ".build/bench", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let cases: [BenchCase] = [
    BenchCase(codec: .h264, width: 3456, height: 2234, fps: 120, yuvInput: false),
    BenchCase(codec: .h264, width: 3456, height: 2234, fps: 120),
    BenchCase(codec: .h264, width: 3456, height: 2234, fps: 120, prioritizeSpeed: true),
    BenchCase(codec: .hevc, width: 3456, height: 2234, fps: 120),
    BenchCase(codec: .hevc, width: 3456, height: 2234, fps: 120, prioritizeSpeed: true),
    BenchCase(codec: .h264, width: 3456, height: 2234, fps: 120, variant: .realTime),
    BenchCase(codec: .h264, width: 3456, height: 2234, fps: 120, variant: .lowLatency),
    BenchCase(codec: .h264, width: 3456, height: 2234, fps: 120, variant: .mainProfile),
    BenchCase(codec: .hevc, width: 3456, height: 2234, fps: 120, prioritizeSpeed: true, variant: .realTime),
    BenchCase(codec: .h264, width: 3456, height: 2234, fps: 60),
    BenchCase(codec: .h264, width: 1728, height: 1118, fps: 120),
]

func converted(_ frames: [CVPixelBuffer], to format: OSType) -> [CVPixelBuffer] {
    var session: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    return frames.map { source in
        var destination: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), format,
                            attributes as CFDictionary, &destination)
        VTPixelTransferSessionTransferImage(session!, from: source, to: destination!)
        return destination!
    }
}

func makeFrames(width: Int, height: Int, count: Int) -> [CVPixelBuffer] {
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return seed >> 33
    }
    let rowHeight = 24
    var runs: [[(start: Int, length: Int)]] = []
    for _ in 0..<(height / rowHeight) {
        var row: [(Int, Int)] = []
        var x = 40 + Int(next() % 80)
        while x < width - 60 {
            let length = 6 + Int(next() % 70)
            row.append((x, length))
            x += length + 4 + Int(next() % 12)
        }
        runs.append(row)
    }

    let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
    return (0..<count).map { index in
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt32.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer) / 4
        let background: UInt32 = 0xFFF4_F4F2
        let ink: UInt32 = 0xFF22_2226
        let accent: UInt32 = 0xFF3A_7BD5
        for y in 0..<height {
            let row = base + y * stride
            row.initialize(repeating: background, count: width)
            let band = y / rowHeight
            let inGlyphs = (y % rowHeight) >= 6 && (y % rowHeight) < 18
            if inGlyphs, band < runs.count {
                let shift = index * 7
                for run in runs[band] {
                    let start = min(width - 1, run.start + shift)
                    let end = min(width, start + run.length)
                    (row + start).update(repeating: ink, count: end - start)
                }
            }
        }
        let blockSize = 160
        let blockX = (index * 97) % (width - blockSize)
        let blockY = (index * 53) % (height - blockSize)
        for y in blockY..<(blockY + blockSize) {
            (base + y * stride + blockX).update(repeating: accent, count: blockSize)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}

func profileLevel(of url: URL, codec: AVVideoCodecType) async -> String {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let description = try? await track.load(.formatDescriptions).first,
          let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
    else { return "unknown" }
    if codec == .h264, let avcC = atoms["avcC"] as? Data, avcC.count > 3 {
        let profiles: [UInt8: String] = [66: "Baseline", 77: "Main", 100: "High"]
        let level = Double(avcC[3]) / 10
        return "\(profiles[avcC[1]] ?? "profile \(avcC[1])") \(level)"
    }
    if codec == .hevc, let hvcC = atoms["hvcC"] as? Data, hvcC.count > 12 {
        let profiles: [UInt8: String] = [1: "Main", 2: "Main 10"]
        let level = Double(hvcC[12]) / 30
        return "\(profiles[hvcC[1] & 0x1F] ?? "profile \(hvcC[1] & 0x1F)") \(level)"
    }
    return "unknown"
}

func run(_ benchCase: BenchCase) async -> BenchResult {
    let frameCount = benchCase.fps * clipSeconds
    let url = outputDirectory.appendingPathComponent("\(benchCase.label.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "@", with: "")).mp4")
    try? FileManager.default.removeItem(at: url)

    func failure(_ message: String) -> BenchResult {
        BenchResult(label: benchCase.label, hardwareRequired: true, frames: 0, seconds: 0, achievedFPS: 0, keepsUp: false,
                    fileBytes: 0, megabitsPerSecond: 0, profileLevel: "-", error: message)
    }

    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return failure("AVAssetWriter init failed") }
    var compression: [String: Any] = [
        AVVideoExpectedSourceFrameRateKey: benchCase.fps,
        AVVideoMaxKeyFrameIntervalKey: benchCase.fps * 2,
    ]
    if benchCase.codec == .h264 {
        compression[AVVideoProfileLevelKey] = benchCase.variant == .mainProfile ? AVVideoProfileLevelH264MainAutoLevel : AVVideoProfileLevelH264HighAutoLevel
    }
    if benchCase.variant == .realTime { compression[kVTCompressionPropertyKey_RealTime as String] = true }
    var encoderSpecification: [String: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
    if benchCase.variant == .lowLatency { encoderSpecification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true }
    if benchCase.prioritizeSpeed { compression[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true }
    let settings: [String: Any] = [
        AVVideoCodecKey: benchCase.codec,
        AVVideoWidthKey: benchCase.width,
        AVVideoHeightKey: benchCase.height,
        AVVideoCompressionPropertiesKey: compression,
        AVVideoEncoderSpecificationKey: encoderSpecification,
    ]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return failure("settings rejected") }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)

    let bgraFrames = makeFrames(width: benchCase.width, height: benchCase.height, count: 8)
    let frames = benchCase.yuvInput ? converted(bgraFrames, to: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) : bgraFrames
    guard writer.startWriting() else { return failure(writer.error?.localizedDescription ?? "startWriting failed") }
    writer.startSession(atSourceTime: .zero)

    let start = Date()
    for index in 0..<frameCount {
        while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 200_000) }
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(benchCase.fps))
        if !adaptor.append(frames[index % frames.count], withPresentationTime: time) {
            return failure(writer.error?.localizedDescription ?? "append failed at frame \(index)")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    let elapsed = Date().timeIntervalSince(start)
    if writer.status != .completed { return failure(writer.error?.localizedDescription ?? "finishWriting failed") }

    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    if bytes == 0 { return failure("writer reported success but the file is empty") }
    let achieved = Double(frameCount) / elapsed
    return BenchResult(
        label: benchCase.label, hardwareRequired: true, frames: frameCount, seconds: elapsed,
        achievedFPS: achieved, keepsUp: achieved >= Double(benchCase.fps),
        fileBytes: bytes, megabitsPerSecond: Double(bytes) * 8 / 1_000_000 / Double(clipSeconds),
        profileLevel: await profileLevel(of: url, codec: benchCase.codec), error: nil)
}

var results: [BenchResult] = []
for benchCase in cases {
    let result = await run(benchCase)
    results.append(result)
    if let error = result.error {
        print("\(result.label): FAILED, \(error)")
    } else {
        print(String(format: "%@: %.0f fps achieved (%@), %.1f Mbit/s, %@", result.label, result.achievedFPS,
                     result.keepsUp ? "keeps up" : "falls behind", result.megabitsPerSecond, result.profileLevel))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(results).write(to: outputDirectory.appendingPathComponent("results.json"))
print("Wrote \(outputDirectory.appendingPathComponent("results.json").path)")
