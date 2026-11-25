import Foundation

/// The file a recording is handed out as. The recording itself stays in the app's Recordings folder as the source, so
/// the preview window can make the clip again at another speed.
public enum Clip {
    /// The recording itself at 1×, untrimmed and not made smaller; otherwise a new file beside it, named with the speed,
    /// the trim and "smaller". `trim` is in seconds from the recording's first frame; `smaller` applies fewer frames and
    /// half size, and `bitRate` the encoder's average bits a second.
    public static func make(from source: URL, speed: Config.Speed, trim: ClosedRange<Double>? = nil, smaller: Smaller = Smaller(),
                            bitRate: Double? = nil) async throws -> URL {
        let shrinks = smaller.changesMP4 || bitRate != nil
        guard speed != .normal || trim != nil || shrinks else { return source }
        let base = source.deletingPathExtension().lastPathComponent
        let name = [base, speed == .normal ? nil : speed.fileSuffix, trim == nil ? nil : "trimmed", shrinks ? "smaller" : nil]
            .compactMap { $0 }.joined(separator: " ")
        let destination = Paths.unusedURL(for: "\(name).mp4", in: source.deletingLastPathComponent())
        do {
            try await Retimer.retime(source, speed: speed.rawValue, trim: trim, fps: smaller.mp4FPS, halfSize: smaller.halfSize,
                                     bitRate: bitRate, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Puts `clip` in `saveFolder` under an unused name, beside the clips made before it, so each copy keeps a file of its
    /// own: a clone when it is the source, a move when it was made from the source. Without a folder it stays where it is.
    /// On failure it also stays where it is, and the error is thrown.
    public static func place(_ clip: URL, source: URL, in saveFolder: URL?) throws -> URL {
        guard let saveFolder else { return clip }
        return clip == source ? try Paths.clone(clip, into: saveFolder) : try Paths.move(clip, into: saveFolder)
    }
}
