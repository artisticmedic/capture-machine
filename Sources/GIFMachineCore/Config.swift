import Foundation

/// Settings from `config.json`, beside `status.json` in Application Support. Missing keys fall back to defaults, so a
/// partial file is valid. A file with an error keeps the values that can still be read and is not rewritten until fixed.
public struct Config: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable, CaseIterable { case mp4, gif }
    public enum AfterCapture: String, Codable, Sendable, CaseIterable { case clipboard, preview, editor }
    /// What a click on the menu bar icon opens (Tim, 2026-11-15: "default is drop down").
    public enum Toolbar: String, Codable, Sendable, CaseIterable { case dropDown, bottomBar, none }
    /// Which keys show in a recording: none, shortcuts and special keys, or everything typed.
    public enum KeyCast: String, Codable, Sendable, CaseIterable { case off, shortcuts, all }
    /// With saving off, how long a clipboard copy stays after the app last copied it (Tim, 2026-11-25: 24 hours and
    /// 30 days beside the 7-day default).
    public enum KeepCopies: Int, Codable, Sendable, CaseIterable {
        case day = 1, week = 7, month = 30

        public var label: String {
            switch self {
            case .day: "24 hours"
            case .week: "7 days"
            case .month: "30 days"
            }
        }

        public var seconds: TimeInterval { TimeInterval(rawValue) * 24 * 60 * 60 }
    }
    /// How fast the clip plays (Tim, 2026-11-15: "half speed, two times speed, or like quarter speed").
    public enum Speed: Double, Codable, Sendable, CaseIterable {
        case quarter = 0.25, half = 0.5, normal = 1, double = 2

        public var label: String {
            switch self {
            case .quarter: "¼×"
            case .half: "½×"
            case .normal: "1×"
            case .double: "2×"
            }
        }

        /// Added to the name of a file made at this speed.
        public var fileSuffix: String {
            switch self {
            case .quarter: "0.25x"
            case .half: "0.5x"
            case .normal: "1x"
            case .double: "2x"
            }
        }
    }

    public var toolbar: Toolbar = .dropDown
    public var format: Format = .mp4
    /// What opens after Stop. The clip goes on the clipboard in every mode.
    public var afterCapture: AfterCapture = .preview
    /// The speed each clip starts at; the preview window can change it per clip.
    public var speed: Speed = .normal
    /// When on and `saveFolder` is set, each recording is moved there and the clipboard holds that file.
    public var save = true
    /// Empty until chosen. A leading `~` is the home folder.
    public var saveFolder = ""
    /// With saving off, days a clipboard copy stays: 1, 7 or 30.
    public var keepCopiesDays: KeepCopies = .week
    /// Key-cast: the keys pressed while recording, drawn into the recording. Off at first.
    public var keyCast: KeyCast = .off
    /// Global shortcuts by `ShortcutAction` name, such as `"section": "ctrl+opt+cmd+s"`. Every action is listed, none set,
    /// so `config.json` shows the names.
    public var shortcuts: [String: String] = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, "") })

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        toolbar = (try? c.decodeIfPresent(Toolbar.self, forKey: .toolbar)) ?? d.toolbar
        format = (try? c.decodeIfPresent(Format.self, forKey: .format)) ?? d.format
        afterCapture = (try? c.decodeIfPresent(AfterCapture.self, forKey: .afterCapture)) ?? d.afterCapture
        speed = (try? c.decodeIfPresent(Speed.self, forKey: .speed)) ?? d.speed
        save = try c.decodeIfPresent(Bool.self, forKey: .save) ?? d.save
        saveFolder = try c.decodeIfPresent(String.self, forKey: .saveFolder) ?? d.saveFolder
        keepCopiesDays = (try? c.decodeIfPresent(KeepCopies.self, forKey: .keepCopiesDays)) ?? d.keepCopiesDays
        shortcuts = (try? c.decodeIfPresent([String: String].self, forKey: .shortcuts)) ?? d.shortcuts
        keyCast = (try? c.decodeIfPresent(KeyCast.self, forKey: .keyCast)) ?? d.keyCast
    }

    public var saveFolderURL: URL? {
        guard save, !saveFolder.isEmpty else { return nil }
        return URL(fileURLWithPath: (saveFolder as NSString).expandingTildeInPath, isDirectory: true)
    }
}

public enum ConfigStore {
    public struct Reading: Sendable {
        public let config: Config
        public let problem: ConfigFile.Problem?
    }

    /// `fallback` is returned when nothing in the data can be read.
    public static func read(_ data: Data, fallback: Config = Config()) -> Reading {
        let reading = ConfigFile.read(data, defaults: defaultsObject())
        guard let values = reading.values, JSONSerialization.isValidJSONObject(values),
              let json = try? JSONSerialization.data(withJSONObject: values),
              let config = try? JSONDecoder().decode(Config.self, from: json)
        else { return Reading(config: fallback, problem: reading.problem ?? ConfigFile.Problem(kind: .syntax)) }
        let unknown = unknownValueKeys(in: values)
        let problem = reading.problem ?? (unknown.isEmpty ? nil : ConfigFile.Problem(kind: .unknownValue, keys: unknown))
        return Reading(config: config, problem: problem)
    }

    /// Writes the defaults when there is no file.
    public static func load(from url: URL, fallback: Config = Config()) -> Reading {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? save(Config(), to: url)
            return Reading(config: Config(), problem: nil)
        }
        return read((try? Data(contentsOf: url)) ?? Data(), fallback: fallback)
    }

    /// Throws `ConfigFile.SaveError.fileHasProblem`, leaving the file as it is, when the file on disk has an error.
    public static func save(_ config: Config, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try? Data(contentsOf: url)
            if let problem = data.map({ read($0).problem }) ?? ConfigFile.Problem(kind: .syntax) {
                throw ConfigFile.SaveError.fileHasProblem(problem)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    private static func defaultsObject() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(Config()) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func unknownValueKeys(in values: [String: Any]) -> [String] {
        var keys: [String] = []
        if let raw = values["afterCapture"] as? String, Config.AfterCapture(rawValue: raw) == nil { keys.append("afterCapture") }
        if let raw = values["format"] as? String, Config.Format(rawValue: raw) == nil { keys.append("format") }
        if let raw = values["speed"] as? Double, Config.Speed(rawValue: raw) == nil { keys.append("speed") }
        if let raw = values["toolbar"] as? String, Config.Toolbar(rawValue: raw) == nil { keys.append("toolbar") }
        if let raw = values["keyCast"] as? String, Config.KeyCast(rawValue: raw) == nil { keys.append("keyCast") }
        if let raw = values["keepCopiesDays"] as? Double, Config.KeepCopies(rawValue: Int(exactly: raw) ?? 0) == nil {
            keys.append("keepCopiesDays")
        }
        if let shortcuts = values["shortcuts"] as? [String: Any] {
            for (key, value) in shortcuts.sorted(by: { $0.key < $1.key }) {
                let text = value as? String
                if text.map({ !$0.isEmpty && Shortcut($0) == nil }) ?? true {
                    keys.append("shortcuts.\(key)")
                }
            }
        }
        return keys
    }
}
