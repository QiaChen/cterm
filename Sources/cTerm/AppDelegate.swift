import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let hostStore: HostStore = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CTERM_EMPTY_STORE"] == "1" {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cterm-empty-\(UUID().uuidString).json")
            return HostStore(fileURL: url)
        }
        #endif
        return HostStore()
    }()
    private let knownHosts = KnownHostsStore()
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var unlockWindowController: UnlockWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu exists from the start so ⌘Q works in the unlock window; it
        // is rebuilt once the main window exists to target it.
        buildMenu()
        // Saved credentials are encrypted with the master password. Without
        // one yet, cTerm starts straight away and asks when something is first
        // saved. With one, nothing that reads credentials (sessions, cloud
        // sync) starts before it is entered.
        let state = CredentialStore.state
        guard state == .locked || CredentialStore.hasUnencryptedCredentials else {
            finishLaunching()
            return
        }
        let unlock = UnlockWindowController(theme: AppearancePreferences.theme) { [weak self] in
            self?.finishLaunching()
        }
        unlockWindowController = unlock
        unlock.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func finishLaunching() {
        let controller = MainWindowController(hostStore: hostStore, knownHosts: knownHosts)
        mainWindowController = controller
        CloudSyncManager.shared.start(hostStore: hostStore)
        buildMenu()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.unlockWindowController = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.shutdown()
    }

    private func configureAboutPanel() {
        let credits = NSAttributedString(
            string: "原生 Swift SSH 客户端\n终端模拟 · 主机指纹校验 · 加密云同步",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "cTerm",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            .credits: credits
        ])
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()
        mainMenu.autoenablesItems = true

        // Application menu.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        let about = NSMenuItem(title: "关于 cTerm", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())

        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(title: "隐藏 cTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 cTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)

        // File menu.
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu

        addItem(to: fileMenu, title: "快速连接…", action: #selector(MainWindowController.newConnection(_:)), key: "n", target: mainWindowController)
        let newHost = NSMenuItem(title: "新建主机…", action: #selector(MainWindowController.newHost(_:)), keyEquivalent: "n")
        newHost.keyEquivalentModifierMask = [.command, .shift]
        newHost.target = mainWindowController
        fileMenu.addItem(newHost)
        addItem(to: fileMenu, title: "新建标签页", action: #selector(MainWindowController.newTab(_:)), key: "t", target: mainWindowController)
        let localTerminal = NSMenuItem(title: "新建本地终端", action: #selector(MainWindowController.newLocalTerminal(_:)), keyEquivalent: "t")
        localTerminal.keyEquivalentModifierMask = [.command, .option]
        localTerminal.target = mainWindowController
        fileMenu.addItem(localTerminal)
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "关闭标签页", action: #selector(MainWindowController.closeTab(_:)), key: "w", target: mainWindowController)
        let closeWindow = NSMenuItem(title: "关闭窗口", action: #selector(MainWindowController.closeWindow(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        closeWindow.target = mainWindowController
        fileMenu.addItem(closeWindow)
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "重新连接", action: #selector(MainWindowController.reconnectCurrent(_:)), key: "r", target: mainWindowController)
        let disconnect = NSMenuItem(title: "断开连接", action: #selector(MainWindowController.disconnectCurrent(_:)), keyEquivalent: "d")
        disconnect.keyEquivalentModifierMask = [.command, .shift]
        disconnect.target = mainWindowController
        fileMenu.addItem(disconnect)

        // Edit menu.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "复制", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(TerminalView.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "清空缓冲区", action: #selector(TerminalView.clearBuffer(_:)), keyEquivalent: "k")
        let resetTerminal = NSMenuItem(title: "重置终端", action: #selector(TerminalView.resetTerminal(_:)), keyEquivalent: "r")
        resetTerminal.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(resetTerminal)

        // Session menu.
        let sessionItem = NSMenuItem()
        mainMenu.addItem(sessionItem)
        let sessionMenu = NSMenu(title: "会话")
        sessionItem.submenu = sessionMenu
        let next = NSMenuItem(title: "下一个标签页", action: #selector(MainWindowController.nextTab(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        next.target = mainWindowController
        sessionMenu.addItem(next)
        let previous = NSMenuItem(title: "上一个标签页", action: #selector(MainWindowController.previousTab(_:)), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        previous.target = mainWindowController
        sessionMenu.addItem(previous)
        sessionMenu.addItem(.separator())
        for index in 1...9 {
            let item = NSMenuItem(title: "标签页 \(index)", action: #selector(MainWindowController.selectTabByNumber(_:)), keyEquivalent: "\(index)")
            item.tag = index
            item.target = mainWindowController
            sessionMenu.addItem(item)
        }
        sessionMenu.addItem(.separator())
        let toggle = NSMenuItem(title: "切换侧边栏", action: #selector(MainWindowController.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .control]
        toggle.target = mainWindowController
        sessionMenu.addItem(toggle)

        // View menu.
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        let zoomIn = NSMenuItem(title: "增大字体", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "减小字体", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        let actual = NSMenuItem(title: "实际大小", action: #selector(actualSize(_:)), keyEquivalent: "0")
        actual.target = self
        viewMenu.addItem(actual)
        viewMenu.addItem(.separator())

        let themeItem = NSMenuItem(title: "主题", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "主题")
        let followTheme = NSMenuItem(title: "跟随系统外观", action: #selector(followSystemTheme(_:)), keyEquivalent: "")
        followTheme.target = self
        themeMenu.addItem(followTheme)
        themeMenu.addItem(.separator())
        for (index, itemTheme) in TerminalTheme.all.enumerated() {
            let item = NSMenuItem(title: itemTheme.name, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        viewMenu.addItem(themeItem)

        // Window menu.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        // Help menu.
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "帮助")
        helpItem.submenu = helpMenu
        let help = NSMenuItem(title: "cTerm 帮助", action: #selector(showHelp(_:)), keyEquivalent: "?")
        help.target = self
        helpMenu.addItem(help)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String, target: AnyObject?) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func showAbout(_ sender: Any?) {
        configureAboutPanel()
    }

    @objc func showSettings(_ sender: Any?) {
        guard mainWindowController != nil else { return } // still locked
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
            settingsWindowController?.onClose = { [weak self] in
                self?.settingsWindowController = nil
            }
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func zoomIn(_ sender: Any?) {
        AppearancePreferences.fontSize = min(24, AppearancePreferences.fontSize + 1)
    }

    @objc private func zoomOut(_ sender: Any?) {
        AppearancePreferences.fontSize = max(10, AppearancePreferences.fontSize - 1)
    }

    @objc private func actualSize(_ sender: Any?) {
        AppearancePreferences.fontSize = 13
    }

    @objc private func selectTheme(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, item.tag >= 0, item.tag < TerminalTheme.all.count else { return }
        AppearancePreferences.theme = TerminalTheme.all[item.tag]
    }

    @objc private func followSystemTheme(_ sender: Any?) {
        AppearancePreferences.followsSystemAppearance = true
    }

    @objc private func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "cTerm 快捷键"
        alert.informativeText = """
        ⌘N  快速连接
        ⇧⌘N  新建主机
        ⌘T  新建标签页
        ⌥⌘T  新建本地终端
        ⌘W  关闭标签页
        ⇧⌘W  关闭窗口
        ⌘R  重新连接
        ⇧⌘D  断开连接
        ⇧⌘] / ⇧⌘[  切换标签页
        ⌘1–9  选择标签页
        ⌘K  清空缓冲区
        ⌥⌘R  重置终端（光标消失或显示异常时使用）
        ⌘= / ⌘- / ⌘0  调整字体大小
        ⌃⌘S  显示或隐藏侧边栏
        ⌘,  设置

        主机密钥首次连接采用 TOFU 校验，指纹会记录在配置目录。认证支持密码、Ed25519 与 RSA 私钥。
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let follows = AppearancePreferences.followsSystemAppearance
        if menuItem.action == #selector(followSystemTheme(_:)) {
            menuItem.state = follows ? .on : .off
        } else if menuItem.action == #selector(selectTheme(_:)) {
            let current = AppearancePreferences.theme
            menuItem.state = !follows && TerminalTheme.all[menuItem.tag].id == current.id ? .on : .off
        }
        return true
    }
}
