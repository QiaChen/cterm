#if DEBUG
import AppKit
import Foundation

/// Development-only runner that opens a real SSH session in the full UI.
/// Start it with the CTERM_UI_* environment variables set, then capture the
/// window with `screencapture -l <window-id>`.
@MainActor
enum UISmokeRunner {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        guard let host = DebugAutomation.host,
              let username = DebugAutomation.username,
              DebugAutomation.password != nil else {
            print("missing CTERM_UI_HOST / CTERM_UI_USER / CTERM_UI_PASSWORD")
            exit(2)
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cterm-ui-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let store = HostStore(fileURL: tempDirectory.appendingPathComponent("hosts.json"))
        let knownHosts = KnownHostsStore(fileURL: tempDirectory.appendingPathComponent("known_hosts.json"))
        let profile = HostProfile(
            name: DebugAutomation.environment("CTERM_UI_NAME") ?? "Rebex 测试",
            host: host,
            port: DebugAutomation.port,
            username: username,
            auth: .password
        )
        store.add(profile)

        let controller = MainWindowController(hostStore: store, knownHosts: knownHosts, theme: .midnight)
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 1240, height: 800))
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        controller.debugOpenSession(profile: profile)

        // Send a command through the keyboard path once the session is up,
        // so the integration run covers focus, key handling and IME plumbing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if let window = controller.window {
                print("first responder: \(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
                let command = DebugAutomation.command ?? "echo KEY_SMOKE_OK"
                sendText(command, into: window)
                sendText("\r", into: window, keyCode: 36)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            print("UI smoke finished")
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static func sendText(_ text: String, into window: NSWindow, keyCode: UInt16 = 0) {
        for character in text {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: String(character),
                charactersIgnoringModifiers: String(character),
                isARepeat: false,
                keyCode: keyCode
            ) else { continue }
            window.sendEvent(event)
        }
    }
}
#endif
