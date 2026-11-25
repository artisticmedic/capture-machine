import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import GIFMachineCore

@Test func customTargetRequiresARepresentablePositiveByteCount() {
    #expect(Smaller.targetBytes(megabytes: "7.25") == 7_250_000)
    #expect(Smaller.targetBytes(megabytes: "0.000001") == 1)
    for value in ["", "-1", "0", "0.0000001", "1e250", "nan", "inf"] {
        #expect(Smaller.targetBytes(megabytes: value) == nil)
    }
}

/// gifski as scripts/build-gifski.sh builds it; the end-to-end tests are skipped until it has been built.
private let gifski = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/gifski/out/bin/gifski")

/// Writes `frames` frames at `fps` as an H.264 MP4: each a different grey, or with `pattern` a moving pattern that
/// compresses like screen content.
private func makeClip(in directory: URL, frames: Int, fps: Int32, width: Int = 320, height: Int = 200, pattern: Bool = false) async throws -> URL {
    let url = directory.appendingPathComponent("REC-test.mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if pattern, let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) {
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = base + y * rowBytes + x * 4
                    pixel[0] = UInt8(truncatingIfNeeded: (x + frame * 3) ^ y)
                    pixel[1] = UInt8(truncatingIfNeeded: x * 2 + y + frame)
                    pixel[2] = UInt8(truncatingIfNeeded: (x / 16 + y / 16 + frame / 4) % 2 * 200)
                    pixel[3] = 255
                }
            }
        } else {
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 8 % 256), CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return url
}

private func withDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gif-machine-gif-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

/// Frame count, size and the delay of the first frame in seconds.
private func inspect(_ gif: URL) throws -> (frames: Int, width: Int, height: Int, delay: Double) {
    let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    let delay = (gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
    return (CGImageSourceGetCount(source), properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties[kCGImagePropertyPixelHeight] as? Int ?? 0, delay)
}

struct GIFMakerTests {
    @Test func aGIFRunsAtTheClipsRateUpToFiftyFPS() {
        #expect(Smaller().fps(clipFPS: 120) == 50)
        #expect(Smaller().fps(clipFPS: 30) == 30)
        #expect(Smaller(frames: .fifteen).fps(clipFPS: 120) == 15)
        #expect(Smaller(frames: .thirty).fps(clipFPS: 20) == 20)
    }

    @Test func framesAreTakenOncePerTick() {
        #expect(GIFMaker.ticks(duration: 1, fps: 50).count == 50)
        #expect(GIFMaker.ticks(duration: 2.5, fps: 10) == (0..<25).map { Double($0) / 10 })
        #expect(GIFMaker.ticks(duration: 0, fps: 50) == [0])
    }

    @Test func coloursConvertToFullRangeBT709() {
        // B, G, R, A for white, black, red, green and blue.
        let pixels: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 255, 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255]
        var out = [UInt8](repeating: 0, count: 15)
        pixels.withUnsafeBufferPointer { YUVPlanes.convert($0.baseAddress!, rowBytes: 20, width: 5, height: 1, into: &out) }
        #expect(Array(out[0..<5]) == [255, 0, 54, 182, 18])
        #expect(Array(out[5..<10]) == [128, 128, 99, 30, 255])
        #expect(Array(out[10..<15]) == [128, 128, 255, 12, 116])
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: gifski.path)))
    func aClipBecomesAGIFAtFiftyFPSAndNativeSize() async throws {
        try await withDirectory { directory in
            let clip = try await makeClip(in: directory, frames: 60, fps: 60)
            let gif = directory.appendingPathComponent("clip.gif")
            try await GIFMaker.make(from: clip, to: gif, options: Smaller(), clipFPS: 60, gifski: gifski)
            let facts = try inspect(gif)
            #expect(facts.width == 320 && facts.height == 200)
            #expect(facts.frames > 1 && facts.frames <= 50)
            #expect(abs(facts.delay - 0.02) < 0.001)
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: gifski.path)))
    func halfSizeAndFewerFramesMakeASmallerGIF() async throws {
        try await withDirectory { directory in
            let clip = try await makeClip(in: directory, frames: 60, fps: 60)
            let full = directory.appendingPathComponent("full.gif"), small = directory.appendingPathComponent("small.gif")
            try await GIFMaker.make(from: clip, to: full, options: Smaller(), clipFPS: 60, gifski: gifski)
            try await GIFMaker.make(from: clip, to: small, options: Smaller(frames: .ten, halfSize: true), clipFPS: 60, gifski: gifski)
            let facts = try inspect(small)
            #expect(facts.width == 160 && facts.height == 100)
            #expect(abs(facts.delay - 0.1) < 0.001)
            let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
            #expect(size(small) < size(full))
        }
    }

    @Test func targetSizeStepsDownFrameRateThenSizeThenQuality() {
        let gif = Smaller().ladder(gif: true)
        #expect(gif.map(\.frames) == [.native, .thirty, .twenty, .fifteen, .ten] + Array(repeating: .ten, count: 6))
        #expect(gif.map(\.halfSize) == Array(repeating: false, count: 5) + Array(repeating: true, count: 6))
        #expect(gif.map(\.quality) == [90, 90, 90, 90, 90, 90, 80, 70, 60, 50, 40])
        #expect(Smaller().ladder(gif: false).count == 6)
        #expect(Smaller(frames: .fifteen, halfSize: true).ladder(gif: false).map(\.frames) == [.fifteen, .ten])
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: gifski.path)))
    func aShortClipsEstimateIsItsSize() async throws {
        try await withDirectory { directory in
            let clip = try await makeClip(in: directory, frames: 12, fps: 60, pattern: true)
            let gif = directory.appendingPathComponent("clip.gif")
            try await GIFMaker.make(from: clip, to: gif, options: Smaller(), clipFPS: 60, gifski: gifski)
            let estimate = try await GIFMaker.estimate(source: clip, trim: nil, speed: 1, options: Smaller(), recordedFPS: 60, gifski: gifski)
            let actual = (try FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
            #expect(abs(Double(estimate - actual)) / Double(actual) < 0.02)
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: gifski.path)))
    func aLongClipsEstimateIsCloseToItsSize() async throws {
        try await withDirectory { directory in
            let clip = try await makeClip(in: directory, frames: 120, fps: 60, pattern: true)
            for options in [Smaller(), Smaller(frames: .fifteen, halfSize: true)] {
                let gif = directory.appendingPathComponent("clip.gif")
                try await GIFMaker.make(from: clip, to: gif, options: options, clipFPS: 60, gifski: gifski)
                let estimate = try await GIFMaker.estimate(source: clip, trim: nil, speed: 1, options: options, recordedFPS: 60,
                                                           gifski: gifski)
                let actual = (try FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
                #expect(abs(Double(estimate - actual)) / Double(actual) < 0.3, "estimate \(estimate), actual \(actual)")
            }
        }
    }
}
