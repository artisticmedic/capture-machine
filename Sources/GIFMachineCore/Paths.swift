import Foundation

/// Files live in `~/Library/Application Support/<CFBundleName>/`: `Capture Machine`, or `Capture Machine Dev` for the
/// development build and for a binary run from `.build`.
public enum Paths {
    public static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Capture Machine Dev"
    }

    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    /// The app was GIF Machine until November 25, 2026. Its first launch under the new name copies `config.json` from
    /// the old folder, so the settings carry over. Recordings and clipboard copies stay where they are.
    public static func adoptFormerConfig(into folder: URL = support, name: String = appName) {
        let former = folder.deletingLastPathComponent()
            .appendingPathComponent(name.replacingOccurrences(of: "Capture Machine", with: "GIF Machine"), isDirectory: true)
            .appendingPathComponent("config.json")
        let target = folder.appendingPathComponent("config.json")
        let files = FileManager.default
        guard former != target, !files.fileExists(atPath: target.path), files.fileExists(atPath: former.path) else { return }
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        try? files.copyItem(at: former, to: target)
    }

    public static var recordings: URL { support.appendingPathComponent("Recordings", isDirectory: true) }
    /// Recordings made with saving off, and the clips made from them. They are deleted when the clip's last window
    /// closes, and at launch.
    public static var temporary: URL { support.appendingPathComponent("Temporary", isDirectory: true) }
    /// Files published with saving off. Each has its own folder so history entries can retain their filenames.
    public static var clipboard: URL { support.appendingPathComponent("Clipboard", isDirectory: true) }
    public static var status: URL { support.appendingPathComponent("status.json") }
    public static var config: URL { support.appendingPathComponent("config.json") }

    /// The path as notices show it, with the home folder as `~`.
    public static func display(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    /// A new recording's file: in Recordings, or with `temporary` in a folder of its own in Temporary, where the clips
    /// made from it go too.
    public static func newRecordingURL(temporary: Bool = false) throws -> URL {
        let folder = temporary ? Self.temporary.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true) : recordings
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return unusedURL(for: "REC-\(formatter.string(from: Date())).mp4", in: folder)
    }

    /// A recording made with saving off.
    public static func isTemporary(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == temporary.standardizedFileURL.path
    }

    /// Moves a finished recording to where `temporary` says it belongs, when saving was switched on or off while it
    /// recorded. Returns where it is.
    public static func relocate(_ recording: URL, temporary: Bool) throws -> URL {
        guard isTemporary(recording) != temporary else { return recording }
        let target = temporary
            ? try newRecordingURL(temporary: true).deletingLastPathComponent().appendingPathComponent(recording.lastPathComponent)
            : unusedURL(for: recording.lastPathComponent, in: recordings)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: recording, to: target)
        if !temporary { try? FileManager.default.removeItem(at: recording.deletingLastPathComponent()) }
        return target
    }

    /// Deletes a recording made with saving off, with the clips made from it.
    public static func discard(_ recording: URL) {
        guard isTemporary(recording) else { return }
        try? FileManager.default.removeItem(at: recording.deletingLastPathComponent())
    }

    /// A GUI and a command-line recording can share this folder. Clean up only our own finished process or an orphan.
    public static func tidyTemporary(in directory: URL = temporary, quitting: Bool = false) {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let name = folder.lastPathComponent
            if UUID(uuidString: name) == nil {
                let parts = name.split(separator: "-", maxSplits: 1)
                guard parts.count == 2, let pid = Int32(parts[0]), pid > 0, UUID(uuidString: String(parts[1])) != nil else { continue }
                if pid != getpid() || !quitting {
                    guard kill(pid, 0) != 0, errno == ESRCH else { continue }
                }
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The same file: one path, or two names for one file.
    public static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path { return true }
        guard let first = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let second = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return first.isEqual(second)
    }

    /// Copies `file` over `destination` in one step: the copy is made beside it first, so a failure leaves `destination`
    /// as it was. Copying a file onto itself does nothing.
    public static func replace(_ destination: URL, withCopyOf file: URL) throws {
        if sameFile(file, destination) { return }
        let folder = destination.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        if clonefile(file.path, staged.path, 0) != 0 {
            try FileManager.default.copyItem(at: file, to: staged)
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Moves `file` into `folder`, creating the folder, under an unused name. Returns where it landed; on failure the
    /// file stays where it was.
    public static func move(_ file: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = unusedURL(for: file.lastPathComponent, in: folder)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// Copies `file` into `folder`, creating the folder, under an unused name. On the same volume the copy is an APFS clone:
    /// instant, and sharing the original's storage until one of them changes.
    public static func clone(_ file: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = unusedURL(for: file.lastPathComponent, in: folder)
        if clonefile(file.path, destination.path, 0) != 0 {
            try FileManager.default.copyItem(at: file, to: destination)
        }
        return destination
    }

    /// `name` in `folder`, or `name 2`, `name 3` and so on when it is taken.
    public static func unusedURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }
}
