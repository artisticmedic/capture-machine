import Foundation
import GIFMachineCore

/// The settings in use. `config.json` is re-read at each use, so an edit by hand or by an agent applies to the next
/// recording without a relaunch.
@MainActor
enum Settings {
    private(set) static var current = Config()
    private static var adoptedFormerConfig = false

    /// A file that cannot be read keeps the last settings that could. Its problem goes to `status.json`, and to the
    /// system log when `log` is on; the command line prints it itself.
    @discardableResult
    static func reload(log: Bool = true) -> Config {
        if !adoptedFormerConfig {
            adoptedFormerConfig = true
            Paths.adoptFormerConfig()
        }
        let reading = ConfigStore.load(from: Paths.config, fallback: current)
        current = reading.config
        let notice = reading.problem?.notice(path: Paths.display(Paths.config))
        if notice != StatusFile.current.configNotice {
            StatusFile.update { $0.configNotice = notice }
            if log, let notice { NSLog("\(Paths.appName): \(notice)") }
        }
        return current
    }
}
