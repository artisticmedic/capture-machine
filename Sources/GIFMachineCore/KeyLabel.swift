import Foundation

/// What key-cast shows for a key press. Ported from karaggeorge's MIT key-cast (kap-key-cast, macos-key-cast), whose
/// glyphs it keeps: ⌃ ⌥ ⇧ ⌘ before the key, and a symbol for each special key.
public enum KeyLabel {
    public struct Label: Equatable, Sendable {
        public let text: String
        /// A plain typed character, which joins the characters typed just before it.
        public let typing: Bool
    }

    /// `characters` is what the key typed; `base` is the key without Option and Control, as menus name it. Returns nil
    /// for a key the mode leaves out.
    public static func label(keyCode: UInt16, modifiers: Shortcut.Modifiers, characters: String?, base: String?,
                             mode: Config.KeyCast) -> Label? {
        guard mode != .off else { return nil }
        let combo = !modifiers.intersection([.command, .control, .option]).isEmpty
        let special = specialKeys[keyCode]
        if combo {
            let key = special ?? (base?.uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
            return Label(text: symbols(modifiers) + key, typing: false)
        }
        // With every key on, Space is part of what's typed.
        if keyCode == 49, mode == .all { return Label(text: " ", typing: true) }
        if let special {
            return Label(text: (modifiers.contains(.shift) ? "⇧" : "") + special, typing: false)
        }
        guard mode == .all, let characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return Label(text: characters, typing: true)
    }

    /// Modifiers held on their own, shown while they're down: ⌃⌥⇧⌘.
    public static func symbols(_ modifiers: Shortcut.Modifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    private static let specialKeys: [UInt16: String] = [
        126: "↑", 125: "↓", 124: "→", 123: "←", 48: "⇥", 53: "⎋", 71: "⎋", 51: "⌫", 117: "⌦", 115: "↖", 119: "↘",
        116: "⇞", 121: "⇟", 36: "↩", 76: "↩", 49: "␣",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
    ]
}
