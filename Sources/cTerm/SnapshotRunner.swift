#if DEBUG
import AppKit
import Foundation

enum SnapshotRunner {
    @MainActor
    static func run(outputPath: String) -> Never {
        // The debug executable shares the "cTerm" defaults domain with local
        // manual runs. Clear window/split autosave state so screenshots are
        // always rendered at the intended size.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame cTermMainWindow")
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames cTermSplitView")
        UserDefaults.standard.removeObject(forKey: "cterm.collapsedGroups")
        UserDefaults.standard.removeObject(forKey: "cterm.sidebarCollapsed")

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cterm-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let store = HostStore(fileURL: tempDirectory.appendingPathComponent("hosts.json"))
        let knownHosts = KnownHostsStore(fileURL: tempDirectory.appendingPathComponent("known_hosts.json"))

        var production = HostProfile(
            name: "生产服务器",
            host: "prod.cterm.dev",
            port: 22,
            username: "cole",
            auth: .privateKey,
            privateKeyPath: "~/.ssh/id_ed25519"
        )
        var development = HostProfile(
            name: "开发机",
            host: "192.168.1.24",
            port: 22,
            username: "cole",
            auth: .password
        )
        var gpu = HostProfile(
            name: "GPU 工作站",
            host: "10.0.0.8",
            port: 2222,
            username: "ml",
            auth: .privateKey,
            privateKeyPath: "~/.ssh/id_rsa"
        )
        let rebex = HostProfile(
            name: "Rebex 测试",
            host: "test.rebex.net",
            port: 22,
            username: "demo",
            auth: .password
        )
        let productionGroup = store.addGroup(named: "生产环境")
        let labGroup = store.addGroup(named: "实验室")
        production.groupID = productionGroup?.id
        development.groupID = productionGroup?.id
        gpu.groupID = labGroup?.id
        for profile in [rebex, gpu, development, production] {
            store.add(profile)
        }

        let theme = TerminalTheme.named(ProcessInfo.processInfo.environment["CTERM_SNAPSHOT_THEME"] ?? "midnight")
        CloudSyncManager.shared.statusOverride = .synced(Date().addingTimeInterval(-180))
        let controller = MainWindowController(hostStore: store, knownHosts: knownHosts, theme: theme)
        guard let window = controller.window else { exit(1) }
        controller.setSnapshotContentSize(NSSize(width: 1240, height: 800))
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        window.makeKey()
        window.contentView?.layoutSubtreeIfNeeded()

        let first = controller.addDemoSession(
            profile: production,
            transcript: productionTranscript,
            remoteTitle: "生产服务器"
        )
        window.contentView?.layoutSubtreeIfNeeded()
        _ = controller.addDemoSession(
            profile: development,
            transcript: developmentTranscript,
            remoteTitle: "开发机 · api"
        )
        _ = controller.addDemoSession(
            profile: production,
            transcript: """
            \u{1B}[1;38;5;114mcole@prod\u{1B}[0m \u{1B}[38;5;110m~/apps/cterm\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m git status -sb
            ## main...origin/main
            \u{1B}[38;5;114m✔\u{1B}[0m working tree clean
            \u{1B}[1;38;5;114mcole@prod\u{1B}[0m \u{1B}[38;5;110m~/apps/cterm\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m
            """,
            remoteTitle: "生产服务器"
        )
        window.contentView?.layoutSubtreeIfNeeded()
        controller.selectDemoSession(id: first.id)
        controller.selectSidebarHost(id: production.id)
        window.contentView?.layoutSubtreeIfNeeded()


        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        first.terminalView.window?.makeFirstResponder(first.terminalView)
        first.terminalView.needsDisplay = true
        window.contentView?.layoutSubtreeIfNeeded()

        if ProcessInfo.processInfo.environment["CTERM_SNAPSHOT_LOCAL"] == "1" {
            // A real local shell end to end: the user's login shell, typed
            // input, Chinese output. Opt-in, since it runs the user's profile.
            controller.newLocalTerminal(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(2.5))
            if let local = controller.selectedSession {
                local.terminalView.window?.makeFirstResponder(local.terminalView)
                local.typeForSnapshot("clear; echo \"本地终端 · $LANG · $TERM\"; echo \"shell=$0 cwd=$PWD\"\r")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            render(window: window, to: outputPath)
            exit(0)
        }
        render(window: window, to: outputPath)

        // A second, wider capture including the titlebar for documentation.
        let url = URL(fileURLWithPath: outputPath)
        let titledURL = url.deletingPathExtension().appendingPathExtension("titled.png")
        renderWindowFrame(window: window, to: titledURL.path)

        if let value = ProcessInfo.processInfo.environment["CTERM_SNAPSHOT_MIDCOLLAPSE"],
           let progress = Double(value) {
            controller.freezeSidebarAnimationForSnapshot(progress: CGFloat(progress))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            renderWindowFrame(window: window, to: url.deletingLastPathComponent()
                .appendingPathComponent("main-midcollapse.titled.png").path)
        }

        controller.setSidebarVisibleForSnapshot(false)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        renderWindowFrame(window: window, to: url.deletingLastPathComponent()
            .appendingPathComponent("main-collapsed.titled.png").path)
        controller.setSidebarVisibleForSnapshot(true)
        window.contentView?.layoutSubtreeIfNeeded()
        UserDefaults.standard.removeObject(forKey: "cterm.sidebarCollapsed")

        if ProcessInfo.processInfo.environment["CTERM_DEMO_HOLD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(first.terminalView)
            }
            NSApp.run()
        }

        renderHostEditor(theme: .midnight, directory: url.deletingLastPathComponent())
        renderSettings(theme: .midnight, directory: url.deletingLastPathComponent())
        renderSecretPrompt(theme: .midnight, directory: url.deletingLastPathComponent())
        renderOverlay(theme: .paper, directory: url.deletingLastPathComponent())
        renderCloudSync(theme: theme, directory: url.deletingLastPathComponent())
        CloudSyncManager.shared.statusOverride = .disabled

        let welcomeStore = HostStore(fileURL: tempDirectory.appendingPathComponent("empty-hosts.json"))
        let welcomeController = MainWindowController(
            hostStore: welcomeStore,
            knownHosts: knownHosts,
            theme: .midnight
        )
        if let welcomeWindow = welcomeController.window {
            welcomeController.setSnapshotContentSize(NSSize(width: 1240, height: 800))
            welcomeWindow.center()
            welcomeController.showWindow(nil)
            welcomeWindow.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            welcomeWindow.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let welcomeURL = url.deletingLastPathComponent().appendingPathComponent("welcome.png")
            render(window: welcomeWindow, to: welcomeURL.path)
            let welcomeTitled = welcomeURL.deletingPathExtension().appendingPathExtension("titled.png")
            renderWindowFrame(window: welcomeWindow, to: welcomeTitled.path)
        }

        exit(0)
    }

    @MainActor
    private static func render(window: NSWindow, to path: String) {
        guard let view = window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }

    @MainActor
    private static func renderWindowFrame(window: NSWindow, to path: String) {
        guard let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }

    @MainActor
    private static func renderSecretPrompt(theme: TerminalTheme, directory: URL) {
        let controller = SecretPromptViewController(
            configuration: .init(
                title: "验证身份",
                message: "生产服务器",
                detail: "cole@prod.cterm.dev:22\n请输入登录密码。",
                fieldPlaceholder: "密码",
                actionTitle: "连接",
                allowsRemembering: true,
                rememberByDefault: true,
                rememberTitle: "记住密码"
            ),
            theme: theme
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "验证身份"
        window.backgroundColor = theme.background
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(controller.preferredContentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        render(window: window, to: directory.appendingPathComponent("password.png").path)
    }

    @MainActor
    private static func renderOverlay(theme: TerminalTheme, directory: URL) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.background.cgColor
        let overlay = SessionOverlayView(theme: theme)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        overlay.showFailure(
            title: "无法连接",
            detail: "连接被拒绝：请检查主机、端口和防火墙设置。"
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "连接失败"
        window.backgroundColor = theme.background
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        root.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        render(window: window, to: directory.appendingPathComponent("overlay.png").path)
    }

    @MainActor
    private static func renderHostEditor(theme: TerminalTheme, directory: URL) {
        let groups = [HostGroup(name: "生产环境"), HostGroup(name: "实验室")]
        let controller = HostEditorViewController(
            theme: theme,
            mode: .create,
            groups: groups,
            preferredGroupID: groups.first?.id
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "新建主机"
        window.backgroundColor = theme.background
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(controller.preferredContentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        render(window: window, to: directory.appendingPathComponent("editor.png").path)
    }

    @MainActor
    private static func renderSettings(theme: TerminalTheme, directory: URL, name: String = "settings.png",
                                       tab: SettingsTab = .general) {
        let controller = SettingsWindowController()
        controller.showTab(tab)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        if let window = controller.window {
            render(window: window, to: directory.appendingPathComponent(name).path)
        }
        controller.close()
    }

    @MainActor
    private static func renderCloudSync(theme: TerminalTheme, directory: URL) {
        let suffix = theme.isDark ? "dark" : "light"
        let previousTheme = AppearancePreferences.theme
        let previousFollow = AppearancePreferences.followsSystemAppearance
        AppearancePreferences.followsSystemAppearance = false
        AppearancePreferences.theme = theme
        defer {
            AppearancePreferences.theme = previousTheme
            AppearancePreferences.followsSystemAppearance = previousFollow
        }

        let manager = CloudSyncManager.shared
        manager.statusOverride = .disabled
        renderSettings(theme: theme, directory: directory, name: "settings-general-\(suffix).png")
        renderSettings(theme: theme, directory: directory, name: "settings-ai-\(suffix).png", tab: .ai)
        renderSettings(theme: theme, directory: directory, name: "settings-sync-off-\(suffix).png", tab: .sync)
        manager.preview = ("cole@outlook.com", "cterm-hosts.ctermsync", Date().addingTimeInterval(-120))
        manager.statusOverride = .synced(Date().addingTimeInterval(-120))
        renderSettings(theme: theme, directory: directory, name: "settings-sync-on-\(suffix).png", tab: .sync)
        manager.preview = nil

        renderSheet(MasterPasswordViewController(
                        mode: .create, theme: theme,
                        reason: "保存主机前，请先创建主密码，用来加密这台主机的密码与私钥。", inSheet: true),
                    theme: theme, to: directory.appendingPathComponent("master-create-\(suffix).png"))
        renderSheet(MasterPasswordViewController(mode: .unlock, theme: theme), theme: theme,
                    to: directory.appendingPathComponent("master-unlock-\(suffix).png"))
        renderSheet(SyncPasswordViewController(mode: .create, theme: theme), theme: theme,
                    to: directory.appendingPathComponent("sync-password-\(suffix).png"))

        let items: [DriveItem] = [
            DriveItem(id: "1", name: "cterm-hosts.ctermsync", size: 4812, lastModifiedDateTime: "2026-10-26T09:12:00Z"),
            DriveItem(id: "2", name: "cterm-hosts-work.ctermsync", size: 2210, lastModifiedDateTime: "2026-09-02T03:40:00Z")
        ]
        let browser = DriveFilePickerViewController(theme: theme) { items }
        renderSheet(browser, theme: theme, to: directory.appendingPathComponent("sync-browser-\(suffix).png"),
                    settle: 0.5)
    }

    @MainActor
    private static func renderSheet(_ controller: NSViewController, theme: TerminalTheme, to url: URL,
                                    settle: TimeInterval = 0.25) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = theme.background
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(controller.preferredContentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        render(window: window, to: url.path)
        window.close()
    }

    private static let productionTranscript = """
    \u{1B}[38;5;109mLast login: Sun Oct 26 18:42:07 2026 from 10.0.0.2\u{1B}[0m
    \u{1B}[1;38;5;114mcole@prod\u{1B}[0m \u{1B}[38;5;110m~/apps/cterm\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m git status -sb
    ## main...origin/main
    \u{1B}[38;5;114m✔\u{1B}[0m working tree clean
    \u{1B}[1;38;5;114mcole@prod\u{1B}[0m \u{1B}[38;5;110m~/apps/cterm\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m swift build -c release
    \u{1B}[38;5;108m[42/42]\u{1B}[0m Build complete! \u{1B}[38;5;244m(8.21s)\u{1B}[0m
    \u{1B}[1;38;5;114mcole@prod\u{1B}[0m \u{1B}[38;5;110m~/apps/cterm\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m ls -la
    total 56
    drwxr-xr-x  14 cole  staff   448 Oct 26 18:41 \u{1B}[1;38;5;39m.\u{1B}[0m
    drwxr-xr-x   6 cole  staff   192 Oct 26 18:30 \u{1B}[1;38;5;39m..\u{1B}[0m
    drwxr-xr-x  10 cole  staff   320 Oct 26 18:41 \u{1B}[1;38;5;39m.git\u{1B}[0m
    -rw-r--r--   1 cole  staff  2148 Oct 26 18:40 \u{1B}[38;5;252mREADME.md\u{1B}[0m
    drwxr-xr-x   4 cole  staff   128 Oct 26 18:39 \u{1B}[1;38;5;39mdist\u{1B}[0m
    drwxr-xr-x  18 cole  staff   576 Oct 26 18:38 \u{1B}[1;38;5;39mSources\u{1B}[0m
    -rwxr-xr-x   1 cole  staff  1720 Oct 26 18:37 \u{1B}[1;38;5;40mbuild.sh\u{1B}[0m
    \u{1B}[1;38;5;114mcole@prod\u{1B}[0m \u{1B}[38;5;110m~/apps/cterm\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m git log --oneline --graph -5
    \u{1B}[38;5;214m*\u{1B}[0m \u{1B}[38;5;220m4f9c2a1\u{1B}[0m \u{1B}[1mfeat:\u{1B}[0m native SSH transport with Citadel
    \u{1B}[38;5;214m*\u{1B}[0m \u{1B}[38;5;220mb31e7d4\u{1B}[0m \u{1B}[1mfeat:\u{1B}[0m terminal grid, IME and 256 colors
    \u{1B}[38;5;214m*\u{1B}[0m \u{1B}[38;5;220m8a02cc9\u{1B}[0m \u{1B}[1mfeat:\u{1B}[0m host key trust on first use
    \u{1B}[38;5;214m*\u{1B}[0m \u{1B}[38;5;220m2de1b70\u{1B}[0m \u{1B}[1mfeat:\u{1B}[0m keychain credentials and tabs
    \u{1B}[38;5;214m*\u{1B}[0m \u{1B}[38;5;220m71c0e88\u{1B}[0m \u{1B}[1mchore:\u{1B}[0m initial project scaffold
    \u{1B}[1;38;5;114mcole@prod\u{1B}[0m \u{1B}[38;5;110m~/apps/cterm\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m fastfetch
    \u{1B}[1;38;5;110m       .:'         \u{1B}[0m  \u{1B}[1mcole@prod\u{1B}[0m
    \u{1B}[1;38;5;110m    __ :'__        \u{1B}[0m  ─────────────────────
    \u{1B}[1;38;5;110m .'\u{1B}[38;5;114m`__`-'__``.     \u{1B}[0m  \u{1B}[38;5;114mOS\u{1B}[0m      macOS 26.6
    \u{1B}[1;38;5;110m:          .-'   \u{1B}[0m  \u{1B}[38;5;114mHost\u{1B}[0m    Mac Studio
    \u{1B}[1;38;5;110m:         :      \u{1B}[0m  \u{1B}[38;5;114mShell\u{1B}[0m   zsh 5.9
    \u{1B}[1;38;5;110m:         :      \u{1B}[0m  \u{1B}[38;5;114mUptime\u{1B}[0m  18 days, 4 hours
    \u{1B}[1;38;5;110m \u{1B}[38;5;114m`.__.-.__.'\u{1B}[0m     \u{1B}[0m  \u{1B}[38;5;114mLoad\u{1B}[0m    0.42  0.31  0.28
    \u{1B}[1;38;5;114mcole@prod\u{1B}[0m \u{1B}[38;5;110m~/apps/cterm\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m
    """

    private static let developmentTranscript = """
    \u{1B}[38;5;109mWelcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic arm64)\u{1B}[0m
    \u{1B}[38;5;109mLast login: Sun Oct 26 17:58:02 2026 from 192.168.1.8\u{1B}[0m
    \u{1B}[1;38;5;114mcole@dev\u{1B}[0m \u{1B}[38;5;110m~/api\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m docker compose ps
    \u{1B}[1mNAME\u{1B}[0m                 \u{1B}[1mIMAGE\u{1B}[0m                          \u{1B}[1mSTATUS\u{1B}[0m
    api-gateway          ghcr.io/cterm/api-gateway     \u{1B}[38;5;114mUp 3 hours (healthy)\u{1B}[0m
    postgres             postgres:16-alpine             \u{1B}[38;5;114mUp 3 hours\u{1B}[0m
    redis                redis:7-alpine                 \u{1B}[38;5;114mUp 3 hours\u{1B}[0m
    worker               ghcr.io/cterm/worker           \u{1B}[38;5;214mRestarting (1) 8s ago\u{1B}[0m
    \u{1B}[1;38;5;114mcole@dev\u{1B}[0m \u{1B}[38;5;110m~/api\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m docker compose logs --tail=5 worker
    worker-1  | \u{1B}[38;5;109m18:44:02\u{1B}[0m INFO  connecting to postgres:5432
    worker-1  | \u{1B}[38;5;109m18:44:02\u{1B}[0m ERROR connection refused
    worker-1  | \u{1B}[38;5;109m18:44:03\u{1B}[0m INFO  retrying in 5s
    \u{1B}[1;38;5;114mcole@dev\u{1B}[0m \u{1B}[38;5;110m~/api\u{1B}[0m \u{1B}[38;5;244m%\u{1B}[0m
    """
}
#endif
