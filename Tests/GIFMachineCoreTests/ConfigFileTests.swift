import Foundation
import Testing
@testable import GIFMachineCore

private var defaults: [String: Any] { [
    "name": "cat", "size": 10.5, "on": true, "keys": ["left": "j", "right": "l"],
] }

private let trailingComma = Data(#"""
{
  "name": "dog",
  "size": 12,
  "on": false,
  "keys": {"left": "a", "right": "d"},
}
"""#.utf8)

private let wrongTypedNumber = Data(#"{"name": "dog", "size": "large", "on": false, "keys": {"left": "a", "right": "d"}}"#.utf8)

private func withDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gif-machine-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func keys(_ values: [String: Any]?) -> [String: String]? { values?["keys"] as? [String: String] }

@Test func aTrailingCommaKeepsEveryKeyAndIsReported() throws {
    try withDirectory { directory in
        let url = directory.appendingPathComponent("config.json")
        try trailingComma.write(to: url)
        let reading = ConfigFile.read(try Data(contentsOf: url), defaults: defaults)
        #expect(reading.values?["name"] as? String == "dog")
        #expect(reading.values?["size"] as? Double == 12)
        #expect(reading.values?["on"] as? Bool == false)
        #expect(keys(reading.values) == ["left": "a", "right": "d"])
        #expect(reading.problem?.kind == .syntax)
        #expect(reading.problem?.line == 5)
    }
}

@Test func aWrongTypedValueKeepsTheOtherKeys() throws {
    try withDirectory { directory in
        let url = directory.appendingPathComponent("config.json")
        try wrongTypedNumber.write(to: url)
        let reading = ConfigFile.read(try Data(contentsOf: url), defaults: defaults)
        #expect(reading.values?["size"] as? Double == 10.5)
        #expect(reading.values?["name"] as? String == "dog")
        #expect(reading.values?["on"] as? Bool == false)
        #expect(keys(reading.values) == ["left": "a", "right": "d"])
        #expect(reading.problem == ConfigFile.Problem(kind: .wrongType, keys: ["size"]))
    }
}

@Test func aWrongTypedNestedValueKeepsItsSiblings() throws {
    try withDirectory { directory in
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"name": "dog", "keys": {"left": 4, "right": "d"}}"#.utf8).write(to: url)
        let reading = ConfigFile.read(try Data(contentsOf: url), defaults: defaults)
        #expect(keys(reading.values) == ["left": "j", "right": "d"])
        #expect(reading.values?["name"] as? String == "dog")
        #expect(reading.problem == ConfigFile.Problem(kind: .wrongType, keys: ["keys.left"]))
    }
}

@Test func anUnreadableFileYieldsNoValues() throws {
    try withDirectory { directory in
        let url = directory.appendingPathComponent("config.json")
        for contents in [Data(#"{"a": "#.utf8), Data()] {
            try contents.write(to: url)
            let reading = ConfigFile.read(try Data(contentsOf: url), defaults: defaults)
            #expect(reading.values == nil)
            #expect(reading.problem?.kind == .syntax)
        }
    }
}

@Test func aFailedFileIsNotRewritten() throws {
    try withDirectory { directory in
        let url = directory.appendingPathComponent("config.json")
        let replacement = Data(#"{"name": "bird"}"#.utf8)
        for failed in [trailingComma, wrongTypedNumber] {
            try failed.write(to: url)
            #expect(throws: ConfigFile.SaveError.self) { try ConfigFile.save(replacement, to: url, defaults: defaults) }
            #expect(try Data(contentsOf: url) == failed)
        }
        try Data(#"{"name": "dog"}"#.utf8).write(to: url)
        try ConfigFile.save(replacement, to: url, defaults: defaults)
        #expect(try Data(contentsOf: url) == replacement)
    }
}

@Test func theNoticeNamesTheFile() {
    let path = "~/Library/Application Support/Capture Machine/config.json"
    #expect(ConfigFile.Problem(kind: .syntax, line: 6).notice(path: path).contains(path))
    #expect(ConfigFile.Problem(kind: .syntax).notice(path: path).contains(path))
    let wrongType = ConfigFile.Problem(kind: .wrongType, keys: ["keys.left"]).notice(path: path)
    #expect(wrongType.contains(path))
    #expect(wrongType.contains("keys.left"))
}

@Test func aCleanFileHasNoProblemAndSaves() throws {
    try withDirectory { directory in
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"name": "dog", "colour": "grey"}"#.utf8).write(to: url)
        let reading = ConfigFile.read(try Data(contentsOf: url), defaults: defaults)
        #expect(reading.problem == nil)
        #expect(reading.values?["name"] as? String == "dog")
        #expect(reading.values?["colour"] == nil)
        #expect(ConfigFile.problem(at: url, defaults: defaults) == nil)
        let replacement = Data(#"{"name": "bird"}"#.utf8)
        try ConfigFile.save(replacement, to: url, defaults: defaults)
        #expect(try Data(contentsOf: url) == replacement)

        let missing = directory.appendingPathComponent("nested/config.json")
        #expect(ConfigFile.problem(at: missing, defaults: defaults) == nil)
        try ConfigFile.save(replacement, to: missing, defaults: defaults)
        #expect(try Data(contentsOf: missing) == replacement)
    }
}
