import Foundation

/// What a global shortcut does. None ship set (Tim, 2026-11-14: "they just need to be configurable. So don't ship any
/// defaults."). Each also stops a recording that's running.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    /// What a click on the menu bar icon does: opens the chooser, or stops.
    case toggle
    case section
    case window
    case fullScreen
    /// Records the remembered section at once.
    case lastSection

    public var title: String {
        switch self {
        case .toggle: "Start or stop"
        case .section: "Record a section"
        case .window: "Record a window"
        case .fullScreen: "Record the full screen"
        case .lastSection: "Record the last section"
        }
    }
}

/// A key with modifiers, written in `config.json` as text such as `ctrl+opt+cmd+r` or `shift+cmd+f5`. Key names follow
/// the US layout's key positions.
public struct Shortcut: Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Parses `ctrl+opt+shift+cmd+<key>`, in any order and case; nil for anything else. A key without Command, Control or
    /// Option must be a function key, so typing never fires one.
    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let code = Self.codes[keyName] else { return nil }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command": modifiers.insert(.command)
            default: return nil
            }
        }
        self.init(keyCode: code, modifiers: modifiers)
        guard isAllowed else { return nil }
    }

    /// Needs Command, Control or Option, unless the key is a function key.
    public var isAllowed: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty || Self.functionKeys.contains(keyCode)
    }

    public var text: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(Self.names[keyCode] ?? "key\(keyCode)")
        return parts.joined(separator: "+")
    }

    /// As menus show it: ⌃⌥⇧⌘R.
    public var display: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + (Self.symbols[keyCode] ?? Self.names[keyCode]?.uppercased() ?? "?")
    }

    public static func name(of keyCode: UInt16) -> String? { names[keyCode] }

    private static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111, "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    private static let names: [UInt16: String] = Dictionary(uniqueKeysWithValues: codes.map { ($0.value, $0.key) })
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    private static let symbols: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

extension Config {
    /// The shortcuts that are set and valid, by action.
    public var parsedShortcuts: [ShortcutAction: Shortcut] {
        var result: [ShortcutAction: Shortcut] = [:]
        for (key, text) in shortcuts {
            guard let action = ShortcutAction(rawValue: key), let shortcut = Shortcut(text) else { continue }
            result[action] = shortcut
        }
        return result
    }
}
