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

        let controller = MainWindowController(hostStore: store, knownHosts: knownHosts, theme: TerminalTheme.named(DebugAutomation.environment("CTERM_UI_THEME") ?? "midnight"))
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 1240, height: 800))
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        // CTERM_UI_WELCOME=<png path>: just the welcome page, captured, then quit.
        if let welcome = DebugAutomation.environment("CTERM_UI_WELCOME") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", welcome]
                try? process.run()
                process.waitUntilExit()
                print("captured welcome")
                exit(0)
            }
            app.run()
        }
        controller.debugOpenSession(profile: profile)
        print("window number: \(window.windowNumber)")
        let frame = window.frame
        let screenHeight = window.screen?.frame.height ?? frame.maxY
        print("window rect: \(Int(frame.minX)) \(Int(screenHeight - frame.maxY)) \(Int(frame.width)) \(Int(frame.height)) \(window.backingScaleFactor)")
        fflush(stdout)

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
        // CTERM_UI_EARLY=<png path>: real pixels 3 s in, e.g. the connecting card.
        if let early = DebugAutomation.environment("CTERM_UI_EARLY") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let number = controller.window?.windowNumber else { return }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", "\(number)", early]
                try? process.run()
                process.waitUntilExit()
                print("captured early")
            }
        }
        // CTERM_UI_LIVERESIZE=1: open and close the SFTP panel mid window-drag;
        // the pane must wait for the drag to end, then appear.
        if DebugAutomation.environment("CTERM_UI_LIVERESIZE") == "1" {
            let host = controller.debugSessionHost
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                host.debugForceLiveResize = true
                controller.toggleSFTPPanel(nil)
                print("live resize: pane shown during drag = \(host.debugSidePaneShown)")
                host.debugForceLiveResize = false
                print("live resize: pane shown after drag = \(host.debugSidePaneShown); \(controller.debugSplitDescription)")
                host.debugForceLiveResize = true
                controller.toggleSFTPPanel(nil)
                print("live resize: pane still shown while closing mid-drag = \(host.debugSidePaneShown)")
                host.debugForceLiveResize = false
                print("live resize: pane shown after second drag = \(host.debugSidePaneShown); \(controller.debugSplitDescription)")
                exit(0)
            }
        }

        // CTERM_UI_AI=<png path>: AI mode against the in-process mock API.
        if let shot = DebugAutomation.environment("CTERM_UI_AI") {
            URLProtocol.registerClass(AIMockProtocol.self)
            setenv("CTERM_AI_BASE_URL", AIMockProtocol.baseURL, 1)
            setenv("CTERM_AI_KEY", "test", 1)
            setenv("CTERM_AI_MODEL", "mock-model", 1)
            // Drawn from the view tree, so it works with the display asleep
            // (no window blur behind the glass, though).
            // Real pixels when the display is awake; otherwise drawn from the
            // view tree (no window blur behind the glass).
            func capture(_ suffix: String) {
                let path = shot.replacingOccurrences(of: ".png", with: "-\(suffix).png")
                if let number = controller.window?.windowNumber {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-o", "-l", "\(number)", path]
                    try? process.run()
                    process.waitUntilExit()
                }
                if !FileManager.default.fileExists(atPath: path), let view = controller.window?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                print("captured \(suffix)")
                fflush(stdout)
            }
            let session = { controller.debugSelectedSession }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                // ⌘ plus the key left of 1, through the app like a real press.
                guard let window = controller.window,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: "·", charactersIgnoringModifiers: "`",
                                                   isARepeat: false, keyCode: 50) else { return }
                NSApp.sendEvent(event)
                print("ai mode after shortcut: \(session()?.isAIModeOn ?? false)")
                // Typed at the terminal: echoed on the AI line, not sent to the shell.
                let question = DebugAutomation.environment("CTERM_UI_AI_QUESTION") ?? "帮我把 a.tar.gz 解压到当前目录"
                sendText(question + "x", into: window)
                sendText("\u{7F}", into: window, keyCode: 51)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.6) { capture("open") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                guard let window = controller.window else { return }
                sendText("\r", into: window, keyCode: 36)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.08) { capture("thinking") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { capture("streaming") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                capture("reply")
                print("phase at reply: \(session()?.debugAIMode?.debugPhase ?? "nil")")
                guard let window = controller.window else { return }
                // ↓ picks the second command, then Enter runs it.
                sendText("\u{F701}", into: window, keyCode: 125)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.4) { capture("second") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.8) {
                guard let window = controller.window else { return }
                sendText("\r", into: window, keyCode: 36)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 13) {
                capture("ran")
                print("ai mode after run: \(session()?.isAIModeOn ?? true)")
                print("terminal tail: \(controller.debugSelectedSession?.terminal.allText().split(separator: "\n").suffix(4) ?? [])")
            }
        }

        // CTERM_UI_SFTP=<png path>: open the SFTP panel, then save a snapshot.
        if let shot = DebugAutomation.environment("CTERM_UI_SFTP") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                controller.toggleSFTPPanel(nil)
            }
            func snapshot(_ path: String) {
                guard let view = controller.window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { snapshot(shot) }
            // Then open a folder and catch the panel mid-load.
            DispatchQueue.main.asyncAfter(deadline: .now() + 13) {
                controller.debugSFTPPanel?.debugOpen("/pub/example")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("panel mid-load: \(controller.debugSFTPPanel?.debugLoadingState ?? "nil")")
                    snapshot(shot.replacingOccurrences(of: ".png", with: "-loading.png"))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    print("panel loaded: \(controller.debugSFTPPanel?.debugLoadingState ?? "nil")")
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cterm-ui-transfers-\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    if DebugAutomation.environment("CTERM_UI_EDIT") == "1" {
                        controller.debugSFTPPanel?.debugEdit("readme.txt")
                    } else {
                        controller.debugSFTPPanel?.debugDemoTransfers(into: folder)
                    }
                }
                // Real pixels: cacheDisplay can't draw the window's blur.
                func capture(_ suffix: String) {
                    guard let number = controller.window?.windowNumber else { return }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-o", "-l", "\(number)",
                                         shot.replacingOccurrences(of: ".png", with: "-\(suffix).png")]
                    try? process.run()
                    process.waitUntilExit()
                    print("captured \(suffix)"); fflush(stdout)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
                    if DebugAutomation.environment("CTERM_UI_HOVER") == "1" {
                        controller.debugSFTPPanel?.debugHoverButtons()
                    }
                    if DebugAutomation.environment("CTERM_UI_PERMS") == "1" {
                        controller.debugSFTPPanel?.debugPermissions()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { capture("running") }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                    capture("transfers")
                    controller.toggleSFTPPanel(nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    print("closed: \(controller.debugSplitDescription)")
                    capture("closed")
                    // Resize the window with the panel closed, as in the bug.
                    if let window = controller.window {
                        var frame = window.frame
                        frame.size.width -= 260
                        window.setFrame(frame, display: true)
                        frame.size.width += 420
                        window.setFrame(frame, display: true)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
                    print("resized: \(controller.debugSplitDescription)")
                    capture("resized")
                    controller.toggleSFTPPanel(nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    print("reopened: \(controller.debugSplitDescription)")
                    capture("reopened")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 32) {
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
