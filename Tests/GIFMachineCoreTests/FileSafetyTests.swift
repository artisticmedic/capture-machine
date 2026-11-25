import Foundation
import Testing
@testable import GIFMachineCore

private func withDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gif-machine-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try body(directory)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

@Test func savingAClipOntoItsOwnFileKeepsIt() throws {
    try withDirectory { directory in
        let clip = directory.appendingPathComponent("clip.mp4")
        try write("clip", to: clip)
        try Paths.replace(clip, withCopyOf: clip)
        #expect(try read(clip) == "clip")
        let link = directory.appendingPathComponent("link.mp4")
        try FileManager.default.linkItem(at: clip, to: link)
        try Paths.replace(link, withCopyOf: clip)
        #expect(try read(clip) == "clip")
    }
}

@Test func replacingWritesOverTheDestination() throws {
    try withDirectory { directory in
        let clip = directory.appendingPathComponent("clip.mp4")
        let destination = directory.appendingPathComponent("saved.mp4")
        try write("new", to: clip)
        try write("old", to: destination)
        try Paths.replace(destination, withCopyOf: clip)
        #expect(try read(destination) == "new")
        #expect(try read(clip) == "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }
}

@Test func aFailedReplaceLeavesTheDestination() throws {
    try withDirectory { directory in
        let clip = directory.appendingPathComponent("clip.mp4")
        let folder = directory.appendingPathComponent("locked", isDirectory: true)
        let destination = folder.appendingPathComponent("saved.mp4")
        try write("new", to: clip)
        try write("old", to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(throws: (any Error).self) { try Paths.replace(destination, withCopyOf: clip) }
        #expect(try read(destination) == "old")
    }
}

@Test func aNewClipIsSavedBesideTheEarlierOnes() throws {
    try withDirectory { directory in
        let source = directory.appendingPathComponent("Recordings/REC.mp4")
        let folder = directory.appendingPathComponent("Saved", isDirectory: true)
        try write("source", to: source)
        let first = try Clip.place(source, source: source, in: folder)
        let made = directory.appendingPathComponent("Recordings/REC 2x.mp4")
        try write("double", to: made)
        let second = try Clip.place(made, source: source, in: folder)
        try write("double again", to: made)
        let third = try Clip.place(made, source: source, in: folder)
        #expect([first, second, third].map(\.lastPathComponent) == ["REC.mp4", "REC 2x.mp4", "REC 2x 2.mp4"])
        #expect(try [first, second, third].map(read) == ["source", "double", "double again"])
        #expect(!FileManager.default.fileExists(atPath: made.path))
        #expect(try read(source) == "source")
    }
}

@Test func aClipThatCannotBePlacedStaysWhereItWasMade() throws {
    try withDirectory { directory in
        let source = directory.appendingPathComponent("Recordings/REC.mp4")
        let folder = directory.appendingPathComponent("Saved", isDirectory: true)
        let saved = folder.appendingPathComponent("REC.mp4")
        try write("source", to: source)
        try write("first", to: saved)
        let made = directory.appendingPathComponent("Recordings/REC smaller.mp4")
        try write("smaller", to: made)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(throws: (any Error).self) { try Clip.place(made, source: source, in: folder) }
        #expect(try read(saved) == "first")
        #expect(try read(made) == "smaller")
    }
}

@Test func temporaryRecordingsHaveAFolderEachInTemporary() {
    let recording = Paths.temporary.appendingPathComponent("A1B2/REC-20261123-150000.mp4")
    #expect(Paths.isTemporary(recording))
    #expect(!Paths.isTemporary(Paths.recordings.appendingPathComponent("REC-20261123-150000.mp4")))
    #expect(!Paths.isTemporary(Paths.temporary.appendingPathComponent("REC-20261123-150000.mp4")))
}

@Test func cleanupKeepsActiveSessionsAndUnrecognizedDirectories() throws {
    try withDirectory { parent in
        let active = parent.appendingPathComponent("\(getpid())-\(UUID().uuidString)")
        let legacy = parent.appendingPathComponent(UUID().uuidString)
        let other = parent.appendingPathComponent("unrelated")
        for folder in [active, legacy, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        Paths.tidyTemporary(in: parent)
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        Paths.tidyTemporary(in: parent, quitting: true)
        #expect(!FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}

@Test func firstLaunchAfterTheRenameCopiesTheFormerSettings() throws {
    try withDirectory { directory in
        let former = directory.appendingPathComponent("GIF Machine Dev/config.json")
        try write(#"{"format":"gif"}"#, to: former)
        let folder = directory.appendingPathComponent("Capture Machine Dev", isDirectory: true)
        Paths.adoptFormerConfig(into: folder, name: "Capture Machine Dev")
        #expect(try read(folder.appendingPathComponent("config.json")) == #"{"format":"gif"}"#)
        #expect(try read(former) == #"{"format":"gif"}"#)
        try write(#"{"format":"mp4"}"#, to: folder.appendingPathComponent("config.json"))
        Paths.adoptFormerConfig(into: folder, name: "Capture Machine Dev")
        #expect(try read(folder.appendingPathComponent("config.json")) == #"{"format":"mp4"}"#)
    }
}
