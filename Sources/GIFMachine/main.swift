import AppKit
import AVFoundation
import GIFMachineCore

// CaptureMachine                     menu bar app
// CaptureMachine status              prints status.json
// CaptureMachine get [key]           prints the settings in use, or one of them, as JSON
// CaptureMachine --render <folder>   writes each surface in light and dark as PNGs
// CaptureMachine record [--seconds N] [--section x,y,w,h] [--hevc]
//                                    records the main screen (section in points, bottom-left origin), saves and copies
//                                    the clip as the settings say, prints the result as JSON and exits
// CaptureMachine export <file> [--speed 0.25|0.5|1|2]
//                                    writes the recording at that speed beside it (default: the speed setting), prints the path

let arguments = Array(CommandLine.arguments.dropFirst())
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

switch arguments.first {
case "status":
    print((try? String(contentsOf: Paths.status, encoding: .utf8)) ?? "{}")

case "--render":
    guard arguments.count > 1 else {
        FileHandle.standardError.write(Data("Give a folder: CaptureMachine --render <folder>\n".utf8))
        exit(1)
    }
    Render.run(to: URL(fileURLWithPath: arguments[1]))

case "get":
    let config = Settings.reload(log: false)
    if let notice = StatusFile.current.configNotice { FileHandle.standardError.write(Data("\(notice)\n".utf8)) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let object = (try? JSONSerialization.jsonObject(with: encoder.encode(config))) as? [String: Any] ?? [:]
    if arguments.count > 1 {
        guard let value = object[arguments[1]] else {
            FileHandle.standardError.write(Data("No setting is named \(arguments[1]). Settings: \(object.keys.sorted().joined(separator: ", ")).\n".utf8))
            exit(1)
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(String(decoding: try encoder.encode(config), as: UTF8.self))
    }

case "record":
    let seconds = value(after: "--seconds").flatMap(Double.init) ?? (arguments.contains("--seconds") ? 0 : 3)
    guard seconds > 0, seconds < Double(UInt64.max) / 1e9 else {
        FileHandle.standardError.write(Data("Give a positive recording duration in seconds.\n".utf8))
        exit(1)
    }
    var section: CGRect?
    if arguments.contains("--section") {
        let parts = value(after: "--section")?.split(separator: ",", omittingEmptySubsequences: false) ?? []
        let values = parts.compactMap { Double($0) }
        guard parts.count == 4, values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
            FileHandle.standardError.write(Data("Give a section as x,y,width,height with positive dimensions.\n".utf8))
            exit(1)
        }
        section = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
    let codec: AVVideoCodecType = arguments.contains("--hevc") ? .hevc : .h264
    Task { @MainActor in
        let recorder = Recorder()
        // With saving off, only the clipboard's copy outlasts the command.
        var made: URL?
        do {
            guard let screen = NSScreen.main else { throw RecorderError.noDisplay }
            try await recorder.start(screen: screen, section: section, codec: codec, temporary: !Settings.reload().save)
            try await Task.sleep(for: .seconds(seconds))
            var recording = try await recorder.stop()
            made = recording.url
            let config = Settings.reload()
            recording = recording.moved(to: try Paths.relocate(recording.url, temporary: !config.save))
            made = recording.url
            var result = try await Delivery.finish(recording, config: config)
            if config.format == .gif {
                let handout = try await Delivery.handOut(source: recording.url, output: Delivery.Output(format: .gif, speed: config.speed),
                                                         recordedFPS: recording.fps, saveFolder: config.saveFolderURL,
                                                         temporary: Paths.isTemporary(recording.url))
                result.path = handout.url.path
                result.format = "gif"
                result.speed = config.speed.rawValue
                result.saveFailure = handout.saveFailure
            }
            if Paths.isTemporary(recording.url), Paths.isTemporary(URL(fileURLWithPath: result.path)) {
                throw RecorderError.failed("The clipboard changed before the temporary clip could be copied.")
            }
            result = await Delivery.inspect(result)
            if Paths.isTemporary(recording.url) {
                Paths.discard(recording.url)
                result.sourcePath = nil
            }
            StatusFile.update { $0.state = "idle"; $0.lastRecording = result; $0.lastError = nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
            exit(0)
        } catch {
            if let made { Paths.discard(made) }
            StatusFile.update { $0.state = "idle"; $0.lastError = error.localizedDescription }
            FileHandle.standardError.write(Data("Recording failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    app.run()

case "export":
    guard arguments.count > 1 else {
        FileHandle.standardError.write(Data("Give a recording: CaptureMachine export <file> [--speed 0.25|0.5|1|2] [--format mp4|gif] [--fps 30|20|15|10] [--half] [--target <MB>] [--estimate]\n".utf8))
        exit(1)
    }
    let source = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
    let config = Settings.reload(log: false)
    let speedText = value(after: "--speed")
    guard let speed = speedText.map({ Double($0).flatMap(Config.Speed.init(rawValue:)) }) ?? config.speed else {
        FileHandle.standardError.write(Data("Speed must be 0.25, 0.5, 1 or 2, not \(speedText ?? "").\n".utf8))
        exit(1)
    }
    let formatText = value(after: "--format")
    guard let format = formatText.map(Config.Format.init(rawValue:)) ?? config.format else {
        FileHandle.standardError.write(Data("Format must be mp4 or gif, not \(formatText ?? "").\n".utf8))
        exit(1)
    }
    let fpsText = value(after: "--fps")
    guard let frames = fpsText.map({ Int($0).flatMap(Smaller.Frames.init(rawValue:)) }) ?? .native, frames != .native || fpsText == nil else {
        FileHandle.standardError.write(Data("A GIF's frame rate must be 30, 20, 15 or 10, not \(fpsText ?? "").\n".utf8))
        exit(1)
    }
    let targetText = value(after: "--target")
    let target = targetText.flatMap(Smaller.targetBytes(megabytes:))
    if arguments.contains("--target"), target == nil {
        FileHandle.standardError.write(Data("Give a positive target size in megabytes.\n".utf8))
        exit(1)
    }
    let output = Delivery.Output(format: format, speed: speed, smaller: Smaller(frames: frames, halfSize: arguments.contains("--half")),
                                 target: target)
    // The recording's own rate, from the file, sets a GIF's rate with the speed.
    Task { @MainActor in
        do {
            let track = try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first
            let rate = try await track?.load(.nominalFrameRate) ?? 60
            if arguments.contains("--estimate") {
                print(try await Delivery.estimate(source: source, output: output, recordedFPS: Int(rate.rounded())))
                exit(0)
            }
            let made = try await Delivery.make(source: source, output: output, recordedFPS: Int(rate.rounded()))
            print(made.url.path)
            if let fitted = made.fitted {
                let settings = [fitted.smaller.summary, fitted.bitRate.map { String(format: "%.1f Mbit/s", $0 / 1_000_000) }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                FileHandle.standardError.write(Data("\(fitted.fits ? "Fits" : "Over the target"): \(fitted.bytes) bytes\(settings.isEmpty ? "" : ", " + settings)\n".utf8))
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    app.run()

default:
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
