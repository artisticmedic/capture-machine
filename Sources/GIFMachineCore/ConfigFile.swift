import Foundation

/// Reads a hand-edited config file without losing what is still valid in it, and refuses to write over a file that has an
/// error. Values are JSON objects as `JSONSerialization` produces them.
public enum ConfigFile {
    public struct Problem: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case syntax, wrongType, unknownValue }

        public let kind: Kind
        /// Dotted key paths, such as `shortcuts.section`, whose values have the wrong type or are not one of the allowed values.
        public let keys: [String]
        /// The 1-based line of a syntax error, when Foundation reports where it is.
        public let line: Int?

        public init(kind: Kind, keys: [String] = [], line: Int? = nil) {
            self.kind = kind
            self.keys = keys
            self.line = line
        }

        public func notice(path: String) -> String {
            let what: String
            switch kind {
            case .syntax:
                what = line.map { "\(path) has an error on line \($0)." } ?? "\(path) is not valid JSON."
            case .wrongType:
                let noun = keys.count == 1 ? "a value" : "values"
                what = "\(path) has \(noun) of the wrong type for \(keys.joined(separator: ", "))."
            case .unknownValue:
                let noun = keys.count == 1 ? "an unknown value" : "unknown values"
                what = "\(path) has \(noun) for \(keys.joined(separator: ", "))."
            }
            return "\(what) Changes are not saved until you fix the file."
        }
    }

    public struct Reading {
        /// The file's values merged onto the defaults, or nil when nothing could be read.
        public let values: [String: Any]?
        public let problem: Problem?
    }

    public enum SaveError: Error { case fileHasProblem(Problem) }

    public static func read(_ data: Data, defaults: [String: Any]) -> Reading {
        var syntax: Problem?
        var object: [String: Any]
        do {
            guard let strict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Reading(values: nil, problem: Problem(kind: .syntax))
            }
            // JSONSerialization accepts a trailing comma without the JSON5 option, so strictness is checked here.
            syntax = trailingCommaLine(in: data).map { Problem(kind: .syntax, line: $0) }
            object = strict
        } catch {
            let problem = Problem(kind: .syntax, line: line(of: error, in: data))
            guard let tolerant = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] else {
                return Reading(values: nil, problem: problem)
            }
            syntax = problem
            object = tolerant
        }
        var wrongTyped: [String] = []
        let merged = merge(object, onto: defaults, path: "", wrongTyped: &wrongTyped)
        return Reading(values: merged, problem: syntax ?? (wrongTyped.isEmpty ? nil : Problem(kind: .wrongType, keys: wrongTyped)))
    }

    /// Nil when there is no file. A file that cannot be opened counts as a syntax problem.
    public static func problem(at url: URL, defaults: [String: Any]) -> Problem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return Problem(kind: .syntax) }
        return read(data, defaults: defaults).problem
    }

    public static func save(_ data: Data, to url: URL, defaults: [String: Any]) throws {
        if let problem = problem(at: url, defaults: defaults) { throw SaveError.fileHasProblem(problem) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func merge(_ file: [String: Any], onto defaults: [String: Any], path: String,
                              wrongTyped: inout [String]) -> [String: Any] {
        var merged = defaults
        for key in defaults.keys.sorted() {
            guard let value = file[key], let fallback = defaults[key] else { continue }
            let keyPath = path.isEmpty ? key : "\(path).\(key)"
            if let fallback = fallback as? [String: Any], let value = value as? [String: Any] {
                merged[key] = merge(value, onto: fallback, path: keyPath, wrongTyped: &wrongTyped)
            } else if kind(of: value) == kind(of: fallback), !(fallback is [String: Any]) {
                merged[key] = value
            } else {
                wrongTyped.append(keyPath)
            }
        }
        return merged
    }

    private enum JSONKind { case string, number, boolean, object, array, null }

    private static func kind(of value: Any) -> JSONKind {
        switch value {
        case is String: return .string
        case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? .boolean : .number
        case is [String: Any]: return .object
        case is [Any]: return .array
        default: return .null
        }
    }

    /// The 1-based line of the first comma that is followed by `}` or `]`, outside string literals.
    private static func trailingCommaLine(in data: Data) -> Int? {
        var line = 1, commaLine: Int?, inString = false, escaped = false
        for byte in data {
            if byte == UInt8(ascii: "\n") { line += 1 }
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: ","): commaLine = line
            case UInt8(ascii: "}"), UInt8(ascii: "]"): if let commaLine { return commaLine }
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"): break
            default:
                commaLine = nil
                inString = byte == UInt8(ascii: "\"")
            }
        }
        return nil
    }

    private static func line(of error: Error, in data: Data) -> Int? {
        let info = (error as NSError).userInfo
        if let index = info["NSJSONSerializationErrorIndex"] as? Int, index >= 0 {
            return data.prefix(index).reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        }
        guard let text = info[NSDebugDescriptionErrorKey] as? String,
              let match = text.range(of: #"line \d+"#, options: .regularExpression) else { return nil }
        return Int(text[match].dropFirst(5))
    }
}
