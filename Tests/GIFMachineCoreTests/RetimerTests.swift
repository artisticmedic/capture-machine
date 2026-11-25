import AVFoundation
import Foundation
import Testing
@testable import GIFMachineCore

/// Writes `frames` frames at `fps`, each a different grey, as an H.264 MP4.
private func makeClip(in directory: URL, frames: Int, fps: Int32, width: Int = 320, height: Int = 200) async throws -> URL {
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
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 4 % 256), CVPixelBufferGetDataSize(pixels))
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

private func measure(_ url: URL) async throws -> (seconds: Double, frames: Int) {
    let asset = AVURLAsset(url: url)
    let seconds = try await asset.load(.duration).seconds
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var frames = 0
    while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
    return (seconds, frames)
}

private func withClipDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gif-machine-clip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

@Test func halfSpeedKeepsEveryFrameAndDoublesTheLength() async throws {
    try await withClipDirectory { directory in
        let source = try await makeClip(in: directory, frames: 60, fps: 120)
        let clip = try await Clip.make(from: source, speed: .half)
        #expect(clip.lastPathComponent == "REC-test 0.5x.mp4")
        let measured = try await measure(clip)
        #expect(measured.frames == 60)
        #expect(abs(measured.seconds - 1.0) < 0.01)
    }
}

@Test func quarterSpeedQuadruplesTheLength() async throws {
    try await withClipDirectory { directory in
        let source = try await makeClip(in: directory, frames: 60, fps: 120)
        let measured = try await measure(try await Clip.make(from: source, speed: .quarter))
        #expect(measured.frames == 60)
        #expect(abs(measured.seconds - 2.0) < 0.01)
    }
}

@Test func doubleSpeedDropsFramesAbove120fps() async throws {
    try await withClipDirectory { directory in
        let source = try await makeClip(in: directory, frames: 60, fps: 120)
        let measured = try await measure(try await Clip.make(from: source, speed: .double))
        #expect(measured.frames == 30)
        #expect(abs(measured.seconds - 0.25) < 0.01)
    }
}

@Test func doubleSpeedOfA60fpsClipKeepsEveryFrame() async throws {
    try await withClipDirectory { directory in
        let source = try await makeClip(in: directory, frames: 30, fps: 60)
        let measured = try await measure(try await Clip.make(from: source, speed: .double))
        #expect(measured.frames == 30)
        #expect(abs(measured.seconds - 0.25) < 0.01)
    }
}

@Test func normalSpeedIsTheRecordingItself() async throws {
    try await withClipDirectory { directory in
        let source = try await makeClip(in: directory, frames: 12, fps: 60)
        #expect(try await Clip.make(from: source, speed: .normal) == source)
    }
}

@Test func placingTheSourceClonesItAndPlacingAMadeClipMovesIt() async throws {
    try await withClipDirectory { directory in
        let source = try await makeClip(in: directory, frames: 12, fps: 60)
        let folder = directory.appendingPathComponent("Saved")
        let cloned = try Clip.place(source, source: source, in: folder)
        #expect(cloned.deletingLastPathComponent().lastPathComponent == "Saved")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: cloned) == Data(contentsOf: source))
        let made = try await Clip.make(from: source, speed: .half)
        let moved = try Clip.place(made, source: source, in: folder)
        #expect(!FileManager.default.fileExists(atPath: made.path))
        #expect(moved.lastPathComponent == "REC-test 0.5x.mp4")
        #expect(try Clip.place(made, source: source, in: nil) == made)
    }
}

@Test func aTrimKeepsThePartBetweenItsTimes() async throws {
    try await withClipDirectory { directory in
        let clip = try await makeClip(in: directory, frames: 60, fps: 60)
        let trimmed = directory.appendingPathComponent("trimmed.mp4")
        try await Retimer.retime(clip, speed: 1, trim: 0.25...0.75, to: trimmed)
        let (seconds, frames) = try await measure(trimmed)
        #expect(abs(seconds - 0.5) < 0.03)
        #expect((29...32).contains(frames))
    }
}

@Test func aTrimBetweenFramesOpensOnTheFrameBeforeIt() async throws {
    try await withClipDirectory { directory in
        let clip = try await makeClip(in: directory, frames: 10, fps: 10)
        let trimmed = directory.appendingPathComponent("trimmed.mp4")
        try await Retimer.retime(clip, speed: 1, trim: 0.25...0.65, to: trimmed)
        let (seconds, frames) = try await measure(trimmed)
        #expect(abs(seconds - 0.4) < 0.03)
        // The frame at 0.2 opens at 0, then 0.3, 0.4, 0.5 and 0.6.
        #expect(frames == 5)
    }
}

@Test func aTrimAtHalfSpeedDoublesItsLength() async throws {
    try await withClipDirectory { directory in
        let clip = try await makeClip(in: directory, frames: 60, fps: 60)
        let trimmed = directory.appendingPathComponent("trimmed.mp4")
        try await Retimer.retime(clip, speed: 0.5, trim: 0.5...1, to: trimmed)
        let (seconds, frames) = try await measure(trimmed)
        #expect(abs(seconds - 1) < 0.05)
        #expect((29...32).contains(frames))
    }
}

@Test func fewerFramesKeepsAboutThatManyFramesASecond() async throws {
    try await withClipDirectory { directory in
        let source = try await makeClip(in: directory, frames: 120, fps: 60)
        let clip = directory.appendingPathComponent("fewer.mp4")
        try await Retimer.retime(source, speed: 1, fps: 15, to: clip)
        let measured = try await measure(clip)
        #expect(abs(measured.seconds - 2) < 0.05)
        #expect((29...31).contains(measured.frames), "\(measured.frames) frames")
    }
}

@Test func halfSizeHalvesTheWidthAndHeight() async throws {
    try await withClipDirectory { directory in
        let source = try await makeClip(in: directory, frames: 30, fps: 30)
        let clip = directory.appendingPathComponent("half.mp4")
        try await Retimer.retime(source, speed: 1, halfSize: true, to: clip)
        let track = try #require(try await AVURLAsset(url: clip).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 160, height: 100))
        #expect(try await measure(clip).frames == 30)
    }
}

@Test func theFrameCountMatchesWhatRetimeKeeps() async throws {
    try await withClipDirectory { directory in
        let source = try await makeClip(in: directory, frames: 240, fps: 120, width: 320, height: 200)
        let times = try await Retimer.frameTimes(source)
        #expect(times.count == 240)
        #expect(times.first == 0)
        let size = CGSize(width: 320, height: 200)
        let cases: [(speed: Double, trim: ClosedRange<Double>?, fps: Int?, halfSize: Bool)] = [
            (1, nil, 15, false), (1, nil, 30, true), (2, nil, nil, false), (2, nil, 20, false),
            (1, 0.5...1.25, nil, false), (1, 0.504...1.5, 10, false), (0.5, 0.25...1, nil, false),
        ]
        for (index, entry) in cases.enumerated() {
            let clip = directory.appendingPathComponent("case-\(index).mp4")
            try await Retimer.retime(source, speed: entry.speed, trim: entry.trim, fps: entry.fps, halfSize: entry.halfSize, to: clip)
            let predicted = Retimer.keptFrames(times, size: size, speed: entry.speed, trim: entry.trim, fps: entry.fps, halfSize: entry.halfSize)
            let measured = try await measure(clip).frames
            #expect(measured == predicted, "case \(index): \(entry), measured \(measured), predicted \(predicted)")
        }
    }
}
