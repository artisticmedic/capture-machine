import AppKit
import GIFMachineCore

/// The clipboard copy. With saving off, each copy is a file of its own in the Clipboard folder that stays after the app
/// quits, so it can be pasted whenever (Tim, 2026-11-23). Copies add up rather than replace each other, so a clipboard
/// history can still paste an earlier one (Tim, later the same day); a copy not put on the clipboard again for `kept` goes.
///
/// Only the clipboard's change count is read, never its contents, so the app never asks to paste.
@MainActor
enum Clipboard {
    private static let fileKey = "clipboardFilePath"
    private static let writtenKey = "clipboardChangeCount"

    /// The change count just after the app last wrote the clipboard, kept across launches.
    private static var written: Int? {
        get { UserDefaults.standard.object(forKey: writtenKey) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: writtenKey) }
    }

    static var count: Int { NSPasteboard.general.changeCount }

    /// Keep copies for, in Settings: 7 days unless changed.
    static var kept: TimeInterval { Settings.current.keepCopiesDays.seconds }

    static func holds(_ file: URL) -> Bool {
        holdsLastCopy && UserDefaults.standard.string(forKey: fileKey) == file.standardizedFileURL.path
    }

    /// The clipboard still holds what the app last put there.
    private static var holdsLastCopy: Bool { written == count }

    /// Puts `file` on the clipboard as a new entry and returns the file it holds. With `temporary`, that's a file in the
    /// Clipboard folder: a clone of `source`, which the clip's windows still play, or else the file itself, moved there.
    static func publish(_ file: URL, temporary: Bool, source: URL) throws -> URL {
        var url = file
        var created: URL?
        if temporary, !inClipboardFolder(file) {
            let folder = Paths.clipboard.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                url = try Paths.clone(file, into: folder)
                created = folder
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            if let created { try? FileManager.default.removeItem(at: created) }
            throw RecorderError.failed("The clip could not be copied to the clipboard.")
        }
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: fileKey)
        written = count
        if created != nil, file != source, Paths.isTemporary(file) {
            try? FileManager.default.removeItem(at: file)
        }
        if inClipboardFolder(url) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        removeExpired(keeping: url)
        return url
    }

    /// At launch: the copies not put on the clipboard for `kept` go, except the one it still holds.
    static func tidy() {
        if holdsLastCopy, let path = UserDefaults.standard.string(forKey: fileKey) {
            removeExpired(keeping: URL(fileURLWithPath: path))
        } else if !(NSPasteboard.general.types ?? []).contains(.fileURL) {
            removeExpired(keeping: nil)
        }
        // A history manager may have restored any file URL. Defer cleanup until the next app copy
        // rather than requesting permission to read that URL.
    }

    static func inClipboardFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == Paths.clipboard.standardizedFileURL.path
    }

    /// Delete only expired, app-created delivery directories whose dates can be read.
    private static func removeExpired(keeping url: URL?) {
        let key = URLResourceKey.contentModificationDateKey
        guard let folders = try? FileManager.default.contentsOfDirectory(at: Paths.clipboard, includingPropertiesForKeys: [key]) else { return }
        let keeping = url?.deletingLastPathComponent().standardizedFileURL.path
        let dated = folders.compactMap { folder -> (URL, Date)? in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  let date = try? folder.resourceValues(forKeys: [key]).contentModificationDate else { return nil }
            return (folder, date)
        }
        for (folder, date) in dated where folder.standardizedFileURL.path != keeping && Date().timeIntervalSince(date) > kept {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
