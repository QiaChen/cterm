#if DEBUG
import AppKit
import Citadel
import Foundation
import TerminalCore

/// Hidden diagnostic entry point used during development:
/// `CTERM_SSH_HOST=... CTERM_SSH_USER=... CTERM_SSH_PASSWORD=... cTerm --ssh-smoke`
@MainActor
enum SSHSmokeTest {
    static func run() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CTERM_SSH_HOST"],
              let user = environment["CTERM_SSH_USER"],
              let password = environment["CTERM_SSH_PASSWORD"] else {
            print("missing CTERM_SSH_* environment variables")
            exit(2)
        }
        let port = Int(environment["CTERM_SSH_PORT"] ?? "22") ?? 22
        let profile = HostProfile(
            name: "smoke",
            host: host,
            port: port,
            username: user,
            auth: .password
        )
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cterm-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let knownHosts = KnownHostsStore(fileURL: temporary.appendingPathComponent("known_hosts.json"))
        let validator = HostKeyValidationDelegate(host: host, port: port, knownHosts: knownHosts) { info in
            print("host key: \(info.algorithm) \(info.fingerprint)")
            return true
        }
        let connection = SSHConnection(
            profile: profile,
            authentication: .passwordBased(username: user, password: password),
            hostKeyValidator: validator,
            cols: 100,
            rows: 30
        )
        let terminal = Terminal(columns: 100, rows: 30)
        var captured = ""

        connection.onData = { data in
            terminal.feed(data)
            captured += String(decoding: data, as: UTF8.self)
            if captured.contains("SMOKE_DONE") {
                print("SSH SMOKE OK")
                print(terminal.allText())
                exit(0)
            }
        }
        connection.onStateChange = { state in
            print("state: \(state)")
            switch state {
            case .connected:
                connection.resize(cols: 120, rows: 40)
                connection.send(text: "echo SMOKE_DONE\r")
            case .failed(let message):
                print("FAILED: \(message)")
                exit(1)
            case .disconnected:
                print("DISCONNECTED")
                exit(1)
            default:
                break
            }
        }
        connection.onEnd = { message in
            print("END: \(message ?? "nil")")
            exit(1)
        }
        connection.onError = { error in
            print("ERROR: \(error)")
        }
        connection.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            print("TIMEOUT")
            exit(3)
        }
        RunLoop.main.run()
        exit(4)
    }
}
#endif
