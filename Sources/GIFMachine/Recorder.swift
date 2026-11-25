import AppKit
import AVFoundation
import GIFMachineCore
@preconcurrency import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay
    case alreadyRecording
    case notRecording
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "That screen isn't available to record."
        case .alreadyRecording: "A recording is already running."
        case .notRecording: "Nothing is recording."
        case .failed(let message): message
        }
    }
}

/// Records one display, or a section of it, straight to an MP4 with `SCRecordingOutput`,
/// at the screen's pixel size and the frame rate `FrameRate` picks for that size.
@MainActor
final class Recorder: NSObject {
    struct Session {
        let stream: SCStream
        let output: SCRecordingOutput
        let url: URL
        let codec: AVVideoCodecType
        let pixelWidth: Int
        let pixelHeight: Int
        let fps: Int
    }

    private(set) var session: Session?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?

    var isRecording: Bool { session != nil }
    /// macOS ended the recording without a stop, as when the screen sharing indicator's Stop is clicked. The recording
    /// is passed when its file was finished and can be played; the error says why it ended.
    var onEndedBySystem: ((Error, Recording?) -> Void)?
    private var outputFinished = false
    private var stopping = false
    private var interrupted: Recording?
    private var recovery: Task<Recording?, Never>?

    /// `section` is in the screen's own points with a bottom-left origin, as AppKit draws it; `nil` records the whole screen.
    /// The recording leaves out the app's own windows that are on screen now, and the windows in `hiding`. With
    /// `temporary` (saving off), it goes in the Temporary folder.
    func start(screen: NSScreen, section: CGRect?, hiding: [CGWindowID] = [], codec: AVVideoCodecType = .h264,
               temporary: Bool = false) async throws {
        guard session == nil else { throw RecorderError.alreadyRecording }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw RecorderError.noDisplay }

        let me = getpid()
        let own = content.windows.filter { $0.owningApplication?.processID == me || hiding.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: own)

        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        let pointRect: CGRect
        if let section {
            let section = section.intersection(CGRect(origin: .zero, size: screen.frame.size))
            guard !section.isEmpty else { throw RecorderError.failed("The recording area is outside the display.") }
            let flippedY = screen.frame.height - section.maxY
            pointRect = CGRect(x: section.minX, y: flippedY, width: section.width, height: section.height).integral
            configuration.sourceRect = pointRect
        } else {
            pointRect = CGRect(origin: .zero, size: screen.frame.size)
        }
        let pixelWidth = Self.even(pointRect.width * scale)
        let pixelHeight = Self.even(pointRect.height * scale)
        let fps = FrameRate.forRecording(displayMaximum: screen.maximumFramesPerSecond, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.queueDepth = 8

        let url = try Paths.newRecordingURL(temporary: temporary)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = codec
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)
        outputFinished = false
        stopping = false
        interrupted = nil
        recovery = nil
        session = Session(stream: stream, output: output, url: url, codec: codec, pixelWidth: pixelWidth, pixelHeight: pixelHeight, fps: fps)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                startContinuation = continuation
                stream.startCapture { error in
                    guard let error else { return }
                    Task { @MainActor in
                        if self.session?.stream === stream { self.resumeStart(.failure(error)) }
                    }
                }
            }
        } catch {
            session = nil
            throw error
        }
    }

    struct Recording: Sendable {
        let url: URL
        let codec: AVVideoCodecType
        let pixelWidth: Int
        let pixelHeight: Int
        let fps: Int
        let stopped: ContinuousClock.Instant
        let fileReady: ContinuousClock.Instant

        func moved(to url: URL) -> Recording {
            Recording(url: url, codec: codec, pixelWidth: pixelWidth, pixelHeight: pixelHeight, fps: fps, stopped: stopped,
                      fileReady: fileReady)
        }
    }

    /// Stops and waits for the file to be finished. The file stays in the Recordings folder as the source for the clip.
    func stop() async throws -> Recording {
        if onEndedBySystem == nil {
            if let recovery, let recording = await recovery.value { return recording }
            if let interrupted {
                self.interrupted = nil
                return interrupted
            }
        }
        guard let session, !stopping else { throw RecorderError.notRecording }
        stopping = true
        defer { self.session = nil }
        let stopped = ContinuousClock.now
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            if self.session?.output === session.output {
                self.resumeFinish(.failure(RecorderError.failed("Timed out waiting for the recording to finish.")))
            }
        }
        defer { deadline.cancel() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                finishContinuation = continuation
                session.stream.stopCapture { error in
                    guard let error else { return }
                    Task { @MainActor in
                        if self.session?.stream === session.stream { self.resumeFinish(.failure(error)) }
                    }
                }
            }
        } catch {
            try? session.stream.removeRecordingOutput(session.output)
            guard let recording = await recover(session, stopped: stopped) else { throw error }
            return recording
        }
        return result(session, stopped: stopped)
    }

    private func result(_ session: Session, stopped: ContinuousClock.Instant) -> Recording {
        Recording(url: session.url, codec: session.codec, pixelWidth: session.pixelWidth, pixelHeight: session.pixelHeight,
                  fps: session.fps, stopped: stopped, fileReady: .now)
    }

    private static func even(_ value: CGFloat) -> Int { max(2, Int(value.rounded()) & ~1) }

    private func resumeStart(_ result: Result<Void, Error>) {
        startContinuation?.resume(with: result)
        startContinuation = nil
    }

    private func resumeFinish(_ result: Result<Void, Error>) {
        finishContinuation?.resume(with: result)
        finishContinuation = nil
    }
}

extension Recorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            if self.session?.output === recordingOutput { self.resumeStart(.success(())) }
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            guard let session = self.session, session.output === recordingOutput else { return }
            self.ended(session, error: error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard let session = self.session, session.output === recordingOutput else { return }
            self.outputFinished = true
            if self.finishContinuation != nil {
                self.resumeFinish(.success(()))
            } else {
                self.ended(session, error: RecorderError.failed("The system finished the recording."))
            }
        }
    }
}

extension Recorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard let session = self.session, session.stream === stream else { return }
            self.ended(session, error: error)
        }
    }

    /// The stream and its recording output can each report the same stop, in either order.
    private func ended(_ session: Session, error: Error) {
        if startContinuation != nil { resumeStart(.failure(error)); return }
        if stopping { resumeFinish(.failure(error)); return }
        stopping = true
        let stopped = ContinuousClock.now
        let task = Task { await recover(session, stopped: stopped) }
        recovery = task
        Task {
            let recording = await task.value
            guard self.session?.output === session.output else { return }
            self.session = nil
            recovery = nil
            if let onEndedBySystem { onEndedBySystem(error, recording) }
            else { interrupted = recording }
        }
    }

    private func recover(_ session: Session, stopped: ContinuousClock.Instant) async -> Recording? {
        for _ in 0..<20 {
            if outputFinished { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let duration = try? await AVURLAsset(url: session.url).load(.duration).seconds
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return result(session, stopped: stopped)
    }
}
