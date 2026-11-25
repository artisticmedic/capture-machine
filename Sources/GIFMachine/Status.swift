import AVFoundation
import ImageIO
import Foundation
import GIFMachineCore

struct RecordingResult: Codable, Sendable {
    /// The clip: in the save folder when saving is on, and on the clipboard.
    var path: String
    /// The recording the clip was made from, kept in the app's Recordings folder.
    var sourcePath: String?
    /// mp4 or gif.
    var format: String?
    var speed: Double?
    var codec: String
    var pixelWidth: Int
    var pixelHeight: Int
    var requestedFPS: Int
    var stopToFileMilliseconds: Double
    /// Nil when Stop copied nothing: for the GIF format, the GIF goes on the clipboard once it's made.
    var stopToClipboardMilliseconds: Double?
    var durationSeconds: Double?
    var frameCount: Int?
    var averageFPS: Double?
    var fileBytes: Int?
    /// Set when saving to the folder failed; the file stayed in the app's Recordings folder.
    var saveFailure: String?
    var captureNotice: String?
}

struct Status: Codable, Sendable {
    var state: String
    var updatedAt: Date
    var lastRecording: RecordingResult?
    var lastError: String?
    /// Set while config.json has an error, in the words the app would show.
    var configNotice: String?
    /// Where the menu bar icon sat two seconds after launch.
    var menuBarIcon: String?
    /// The last launch that opened a chooser.
    var launch: Launch?
    /// The permission guide's list and step while it is open, such as "screen password".
    var permissionGuide: String?

    struct Launch: Codable, Sendable {
        /// From the process starting to the chooser opening.
        var toChooserMilliseconds: Double
        /// The part of that spent waiting for the menu bar icon's place, which the drop-down hangs from.
        var iconWaitMilliseconds: Double
        var toolbar: String
    }
}

@MainActor
enum StatusFile {
    /// Starts from the file on disk, so the last recording and a config notice outlive the process that wrote them.
    private(set) static var current: Status = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: Paths.status)).flatMap { try? decoder.decode(Status.self, from: $0) }
            ?? Status(state: "idle", updatedAt: Date())
    }()

    static func update(_ change: (inout Status) -> Void) {
        change(&current)
        current.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try encoder.encode(current).write(to: Paths.status, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("status.json not written: \(error.localizedDescription)\n".utf8))
        }
    }
}

enum ClipInspector {
    struct Facts: Sendable {
        var durationSeconds: Double
        var frameCount: Int
        var fileBytes: Int
    }

    static func facts(for url: URL) async throws -> Facts {
        if url.pathExtension.lowercased() == "gif" { return try gifFacts(for: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return Facts(durationSeconds: duration, frameCount: 0, fileBytes: fileSize(url))
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            frames += CMSampleBufferGetNumSamples(sample)
        }
        return Facts(durationSeconds: duration, frameCount: frames, fileBytes: fileSize(url))
    }

    /// A GIF's frames and length from its frame delays.
    private static func gifFacts(for url: URL) throws -> Facts {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let count = CGImageSourceGetCount(source)
        let seconds = (0..<count).reduce(0.0) { total, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return total + ((gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0)
        }
        return Facts(durationSeconds: seconds, frameCount: count, fileBytes: fileSize(url))
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
