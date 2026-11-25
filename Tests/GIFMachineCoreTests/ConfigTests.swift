import Foundation
import Testing
@testable import GIFMachineCore

private func withDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gif-machine-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Test func theDefaultsMatchThePlan() {
    let config = Config()
    #expect(config.toolbar == .dropDown)
    #expect(config.format == .mp4)
    #expect(config.afterCapture == .preview)
    #expect(config.save)
    #expect(config.saveFolder.isEmpty)
    #expect(config.saveFolderURL == nil)
    #expect(config.speed == .normal)
    #expect(config.keepCopiesDays == .week)
}

@Test func keepCopiesForReadsDaysAndReportsOtherValues() {
    #expect(ConfigStore.read(Data(#"{"keepCopiesDays": 30}"#.utf8)).config.keepCopiesDays == .month)
    #expect(ConfigStore.read(Data(#"{"keepCopiesDays": 1}"#.utf8)).config.keepCopiesDays.seconds == 86_400)
    let reading = ConfigStore.read(Data(#"{"keepCopiesDays": 14}"#.utf8))
    #expect(reading.config.keepCopiesDays == .week)
    #expect(reading.problem == ConfigFile.Problem(kind: .unknownValue, keys: ["keepCopiesDays"]))
}

@Test func aMissingFileIsWrittenWithTheDefaults() throws {
    try withDirectory { directory in
        let url = directory.appendingPathComponent("config.json")
        let reading = ConfigStore.load(from: url)
        #expect(reading.config == Config())
        #expect(reading.problem == nil)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(written?["format"] as? String == "mp4")
        #expect(written?["afterCapture"] as? String == "preview")
    }
}

@Test func aPartialFileKeepsTheOtherDefaults() {
    let reading = ConfigStore.read(Data(#"{"format": "gif"}"#.utf8))
    #expect(reading.config.format == .gif)
    #expect(reading.config.afterCapture == .preview)
    #expect(reading.problem == nil)
}

@Test func anUnknownValueFallsBackAndIsReported() {
    let reading = ConfigStore.read(Data(#"{"format": "webm", "afterCapture": "clipboard"}"#.utf8))
    #expect(reading.config.format == .mp4)
    #expect(reading.config.afterCapture == .clipboard)
    #expect(reading.problem == ConfigFile.Problem(kind: .unknownValue, keys: ["format"]))
    #expect(reading.problem?.notice(path: "config.json") == "config.json has an unknown value for format. Changes are not saved until you fix the file.")
}

@Test func anUnreadableFileKeepsTheFallback() {
    var fallback = Config()
    fallback.afterCapture = .editor
    let reading = ConfigStore.read(Data(#"{"format": "#.utf8), fallback: fallback)
    #expect(reading.config == fallback)
    #expect(reading.problem?.kind == .syntax)
}

@Test func aFileWithAnErrorIsNotOverwritten() throws {
    try withDirectory { directory in
        let url = directory.appendingPathComponent("config.json")
        for broken in [#"{"format": "webm"}"#, #"{"save": "yes"}"#, #"{"format": "#] {
            try Data(broken.utf8).write(to: url)
            #expect(throws: ConfigFile.SaveError.self) { try ConfigStore.save(Config(), to: url) }
            #expect(try String(contentsOf: url, encoding: .utf8) == broken)
        }
        try Data(#"{"format": "gif"}"#.utf8).write(to: url)
        try ConfigStore.save(Config(), to: url)
        #expect(ConfigStore.load(from: url).config == Config())
    }
}

@Test func theSaveFolderExpandsTheHomeFolderAndNeedsSavingOn() {
    var config = Config()
    config.saveFolder = "~/Pictures/Screenshots"
    #expect(config.saveFolderURL?.path == NSHomeDirectory() + "/Pictures/Screenshots")
    config.save = false
    #expect(config.saveFolderURL == nil)
}

@Test func takenNamesGetANumber() throws {
    try withDirectory { directory in
        #expect(Paths.unusedURL(for: "REC-1.mp4", in: directory).lastPathComponent == "REC-1.mp4")
        try Data().write(to: directory.appendingPathComponent("REC-1.mp4"))
        #expect(Paths.unusedURL(for: "REC-1.mp4", in: directory).lastPathComponent == "REC-1 2.mp4")
        try Data().write(to: directory.appendingPathComponent("REC-1 2.mp4"))
        #expect(Paths.unusedURL(for: "REC-1.mp4", in: directory).lastPathComponent == "REC-1 3.mp4")
    }
}

@Test func aRecordingMovesIntoANewFolderAndKeepsItsName() throws {
    try withDirectory { directory in
        let file = directory.appendingPathComponent("REC-1.mp4")
        try Data("clip".utf8).write(to: file)
        let folder = directory.appendingPathComponent("Screenshots/Clips", isDirectory: true)
        let landed = try Paths.move(file, into: folder)
        #expect(landed.path == folder.appendingPathComponent("REC-1.mp4").path)
        #expect(try Data(contentsOf: landed) == Data("clip".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try Data("second".utf8).write(to: file)
        #expect(try Paths.move(file, into: folder).lastPathComponent == "REC-1 2.mp4")
    }
}

@Test func aFailedMoveLeavesTheRecordingWhereItWas() throws {
    try withDirectory { directory in
        let file = directory.appendingPathComponent("REC-1.mp4")
        try Data("clip".utf8).write(to: file)
        let locked = directory.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) { try Paths.move(file, into: locked) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Test func theToolbarStyleReadsAndRejectsUnknownNames() {
    #expect(ConfigStore.read(Data(#"{"toolbar": "bottomBar"}"#.utf8)).config.toolbar == .bottomBar)
    #expect(ConfigStore.read(Data(#"{"toolbar": "none"}"#.utf8)).config.toolbar == Config.Toolbar.none)
    let unknown = ConfigStore.read(Data(#"{"toolbar": "floating"}"#.utf8))
    #expect(unknown.config.toolbar == .dropDown)
    #expect(unknown.problem == ConfigFile.Problem(kind: .unknownValue, keys: ["toolbar"]))
}

@Test func speedIsANumber() throws {
    let reading = ConfigStore.read(Data(#"{"speed": 0.5}"#.utf8))
    #expect(reading.config.speed == .half)
    #expect(reading.problem == nil)
    #expect(ConfigStore.read(Data(#"{"speed": 2}"#.utf8)).config.speed == .double)
    var config = Config()
    config.speed = .quarter
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
    #expect(encoded?["speed"] as? Double == 0.25)
}

@Test func anUnlistedSpeedIsReported() {
    let unlisted = ConfigStore.read(Data(#"{"speed": 3}"#.utf8))
    #expect(unlisted.config.speed == .normal)
    #expect(unlisted.problem == ConfigFile.Problem(kind: .unknownValue, keys: ["speed"]))
    let text = ConfigStore.read(Data(#"{"speed": "0.5"}"#.utf8))
    #expect(text.problem == ConfigFile.Problem(kind: .wrongType, keys: ["speed"]))
}

@Test func shortcutsReadFromTextAndBack() throws {
    let shortcut = try #require(Shortcut("ctrl+opt+cmd+r"))
    #expect(shortcut.keyCode == 15)
    #expect(shortcut.modifiers == [.control, .option, .command])
    #expect(shortcut.text == "ctrl+opt+cmd+r")
    #expect(shortcut.display == "⌃⌥⌘R")
    #expect(Shortcut("Shift+Cmd+F5")?.display == "⇧⌘F5")
    #expect(Shortcut("f5")?.text == "f5")
    #expect(Shortcut("shift+r") == nil, "a typed key can't be a shortcut")
    #expect(Shortcut("cmd+nope") == nil)
    #expect(Shortcut("hyper+r") == nil)
}

@Test func shortcutsInTheConfigFile() {
    let reading = ConfigStore.read(Data(#"{"shortcuts": {"section": "ctrl+opt+cmd+s", "toggle": ""}}"#.utf8))
    #expect(reading.problem == nil)
    #expect(reading.config.parsedShortcuts == [.section: Shortcut("ctrl+opt+cmd+s")!])
    // Only the actions the app knows are read; another name is left alone.
    let wrong = ConfigStore.read(Data(#"{"shortcuts": {"section": "shift+s", "dance": "cmd+d"}}"#.utf8))
    #expect(wrong.problem == ConfigFile.Problem(kind: .unknownValue, keys: ["shortcuts.section"]))
    #expect(wrong.config.parsedShortcuts.isEmpty)
}

@Test func keyCastLabelsShortcutsAndTyping() {
    #expect(KeyLabel.label(keyCode: 1, modifiers: [.command, .shift], characters: "S", base: "s", mode: .shortcuts)
        == KeyLabel.Label(text: "⇧⌘S", typing: false))
    #expect(KeyLabel.label(keyCode: 36, modifiers: [], characters: "\r", base: "\r", mode: .shortcuts)?.text == "↩")
    #expect(KeyLabel.label(keyCode: 123, modifiers: [.shift], characters: nil, base: nil, mode: .shortcuts)?.text == "⇧←")
    #expect(KeyLabel.label(keyCode: 49, modifiers: [], characters: " ", base: " ", mode: .all) == KeyLabel.Label(text: " ", typing: true))
    #expect(KeyLabel.label(keyCode: 49, modifiers: [], characters: " ", base: " ", mode: .shortcuts)?.text == "␣")
    // Plain typing shows only with every key on.
    #expect(KeyLabel.label(keyCode: 0, modifiers: [], characters: "a", base: "a", mode: .shortcuts) == nil)
    #expect(KeyLabel.label(keyCode: 0, modifiers: [.shift], characters: "A", base: "A", mode: .all)
        == KeyLabel.Label(text: "A", typing: true))
    #expect(KeyLabel.label(keyCode: 0, modifiers: [.option], characters: "å", base: "a", mode: .shortcuts)?.text == "⌥A")
    #expect(KeyLabel.label(keyCode: 0, modifiers: [.command], characters: "a", base: "a", mode: .off) == nil)
}
