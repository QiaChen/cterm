#if DEBUG
import Foundation

/// Development-only hooks used by the `--ui-ssh` integration runner.
/// None of this code is compiled into release builds.
enum DebugAutomation {
    static func environment(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        return value?.isEmpty == false ? value : nil
    }

    static var host: String? { environment("CTERM_UI_HOST") }
    static var username: String? { environment("CTERM_UI_USER") }
    static var password: String? { environment("CTERM_UI_PASSWORD") }
    static var port: Int { Int(environment("CTERM_UI_PORT") ?? "22") ?? 22 }
    static var command: String? { environment("CTERM_UI_COMMAND") }
    static var trustHostKey: Bool { environment("CTERM_UI_TRUST") == "1" }

    static func matches(_ profile: HostProfile) -> Bool {
        guard let host else { return false }
        return profile.host.caseInsensitiveCompare(host) == .orderedSame
    }
}
#endif
