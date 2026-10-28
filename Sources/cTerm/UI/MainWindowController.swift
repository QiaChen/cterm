import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let hostStore: HostStore
    private let knownHosts: KnownHostsStore
    private var theme: TerminalTheme
    private let sidebarVC: SidebarViewController
    private let sessionHost: SessionHostViewController
    private let rootVC: RootViewController
    private var contentWidthConstraint: NSLayoutConstraint!
    private var contentHeightConstraint: NSLayoutConstraint!
    private var recordedConnections: Set<UUID> = []
    private var isApplyingWindowSize = false
    private var hasCompletedInitialPresentation = false
    private let ignoresSystemAppearance: Bool
    private var appearanceObserver: NSObjectProtocol?
    private var aiShortcutMonitor: Any?

    init(hostStore: HostStore, knownHosts: KnownHostsStore, theme: TerminalTheme? = nil) {
        let initialTheme = theme ?? AppearancePreferences.theme
        self.ignoresSystemAppearance = theme != nil
        self.hostStore = hostStore
        self.knownHosts = knownHosts
        self.theme = initialTheme
        self.sidebarVC = SidebarViewController(hostStore: hostStore, theme: initialTheme)
        self.sessionHost = SessionHostViewController(theme: initialTheme)
        self.rootVC = RootViewController(sidebar: self.sidebarVC, sessionHost: self.sessionHost, theme: initialTheme)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "cTerm"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.minSize = NSSize(width: 900, height: 560)
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: initialTheme.isDark ? .darkAqua : .aqua)
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = false
        super.init(window: window)
        installAIShortcut()

        window.delegate = self
        sidebarVC.delegate = self
        sessionHost.delegate = self
        sessionHost.onNewHost = { [weak self] in self?.showNewHost() }
        sessionHost.onQuickConnect = { [weak self] in self?.showQuickConnect() }
        sessionHost.onLocalTerminal = { [weak self] in self?.newLocalTerminal(nil) }
        sessionHost.onSelectionChanged = { [weak self] session in
            self?.updateWindowTitle(session: session)
        }

        let defaults = UserDefaults.standard
        var initialWidth = defaults.double(forKey: "cterm.windowContentWidth")
        var initialHeight = defaults.double(forKey: "cterm.windowContentHeight")
        if initialWidth < 900 { initialWidth = 1180 }
        if initialHeight < 560 { initialHeight = 760 }
        if let screen = NSScreen.main {
            initialWidth = min(initialWidth, max(900, screen.visibleFrame.width - 40))
            initialHeight = min(initialHeight, max(560, screen.visibleFrame.height - 40))
        }
        rootVC.view.frame = NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight)
        contentWidthConstraint = rootVC.view.widthAnchor.constraint(equalToConstant: initialWidth)
        contentHeightConstraint = rootVC.view.heightAnchor.constraint(equalToConstant: initialHeight)
        // Below .dragThatCanResizeWindow (510): these only remember the size.
        // At a higher priority AppKit treats them as the window's fixed size and
        // turns off resizing from the edges entirely.
        contentWidthConstraint.priority = .dragThatCannotResizeWindow
        contentHeightConstraint.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([contentWidthConstraint, contentHeightConstraint])
        window.contentViewController = rootVC
        window.setContentSize(NSSize(width: initialWidth, height: initialHeight))
        window.center()

        hostStore.onChange = { [weak self] in
            self?.sidebarVC.refresh()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(themePreferenceChanged(_:)),
            name: .ctermThemeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontPreferenceChanged(_:)),
            name: .ctermFontSizeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.systemAppearanceDidChange()
        }
    }

    #if DEBUG
    var selectedSession: SessionViewController? { sessionHost.selectedSession }

    func setSidebarVisibleForSnapshot(_ visible: Bool) {
        rootVC.endSnapshotFreeze()
        rootVC.setSidebarVisible(visible)
    }

    func freezeSidebarAnimationForSnapshot(progress: CGFloat) {
        rootVC.layoutForSnapshot(collapseProgress: progress)
    }
    #endif

    func setSnapshotContentSize(_ size: NSSize) {
        contentWidthConstraint?.constant = size.width
        contentHeightConstraint?.constant = size.height
        window?.setContentSize(size)
        window?.center()
    }

    private func syncContentSizeConstraints(to size: NSSize, save: Bool) {
        guard contentWidthConstraint != nil, contentHeightConstraint != nil else { return }
        let width = max(900, size.width)
        let height = max(560, size.height)
        if abs(contentWidthConstraint.constant - width) > 0.5 ||
            abs(contentHeightConstraint.constant - height) > 0.5 {
            isApplyingWindowSize = true
            contentWidthConstraint.constant = width
            contentHeightConstraint.constant = height
            isApplyingWindowSize = false
        }
        if save {
            UserDefaults.standard.set(width, forKey: "cterm.windowContentWidth")
            UserDefaults.standard.set(height, forKey: "cterm.windowContentHeight")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// ⌘ plus the key left of 1 toggles AI mode. Matched by key code, so it
    /// works whatever that key types (` or · with a Chinese input source), and
    /// before the system can take ⌘` for cycling windows.
    private func installAIShortcut() {
        aiShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 50, modifiers == .command, let self, let window = self.window,
                  event.window === window, window.attachedSheet == nil else { return event }
            self.toggleAIMode(nil)
            return nil
        }
    }

    deinit {
        if let aiShortcutMonitor { NSEvent.removeMonitor(aiShortcutMonitor) }
        NotificationCenter.default.removeObserver(self)
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasCompletedInitialPresentation = true
            if self.sessionHost.sessions.isEmpty {
                self.window?.makeFirstResponder(nil)
            }
        }
    }


    // MARK: - Host actions

    @objc func newHost(_ sender: Any?) {
        showNewHost()
    }

    @objc func newConnection(_ sender: Any?) {
        showQuickConnect()
    }

    @objc func newLocalTerminal(_ sender: Any?) {
        openSession(profile: .localShell())
    }

    @objc func newTab(_ sender: Any?) {
        if let profile = selectedSidebarProfile {
            openSession(profile: profile)
        } else {
            showQuickConnect()
        }
    }

    private var selectedSidebarProfile: HostProfile? {
        sidebarVC.selectedProfile
    }

    private func showNewHost() {
        presentHostEditor(mode: .create, session: nil, preferredGroupID: nil)
    }

    private func showQuickConnect() {
        presentHostEditor(mode: .quickConnect, session: nil, preferredGroupID: nil)
    }

    private func showNewHost(inGroup groupID: UUID?) {
        presentHostEditor(mode: .create, session: nil, preferredGroupID: groupID)
    }

    private func presentHostEditor(mode: HostEditorViewController.Mode, session: SessionViewController?,
                                   preferredGroupID: UUID?) {
        let editor = HostEditorViewController(
            theme: theme,
            mode: mode,
            groups: hostStore.groups,
            preferredGroupID: preferredGroupID
        )
        editor.onCancel = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.contentViewController?.dismiss(editor)
        }
        editor.onSave = { [weak self, weak editor] profile, persist in
            guard let self, let editor else { return }
            self.contentViewController?.dismiss(editor)
            switch mode {
            case .quickConnect:
                var quick = profile
                quick.isTemporary = true
                self.openSession(profile: quick)
            case .create:
                self.hostStore.add(profile)
                self.sidebarVC.refresh()
                self.sidebarVC.selectHost(id: profile.id)
            case .edit(let old):
                self.hostStore.update(profile)
                self.sidebarVC.refresh()
                self.sidebarVC.selectHost(id: profile.id)
                // The same host can be open in several tabs; keep all of them
                // in sync when its name, endpoint or group changes.
                for current in self.sessionHost.sessions where current.profile.id == profile.id {
                    current.refreshProfile(profile)
                }
                _ = old
            }
            _ = persist
        }
        contentViewController?.presentAsSheet(editor)
    }

    private func editHost(_ profile: HostProfile, session: SessionViewController?) {
        guard !profile.isLocal else { return } // a local shell has nothing to edit
        // Use the store as the source of truth so a host moved/deleted from a
        // group by another tab does not get stale metadata.
        let current = hostStore.host(withID: profile.id) ?? profile
        presentHostEditor(mode: .edit(current), session: session, preferredGroupID: current.groupID)
    }

    private func deleteHost(_ profile: HostProfile) {
        let sessions = sessionHost.sessions.filter { $0.profile.id == profile.id }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除主机“\(profile.displayName)”？"
        alert.informativeText = sessions.isEmpty
            ? "此操作会同时删除本机保存的密码或私钥口令。"
            : "此操作会关闭 \(sessions.count) 个相关会话，并删除本机保存的密码或私钥口令。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            for session in sessions {
                if let index = self.sessionHost.sessions.firstIndex(where: { $0.id == session.id }) {
                    self.closeSession(at: index)
                }
            }
            CredentialStore.deleteSecrets(for: profile.id)
            self.hostStore.remove(id: profile.id)
            self.sidebarVC.refresh()
            self.updateSidebarStatuses()
        }
    }

    private func openSession(profile: HostProfile) {
        // Every connect action opens a fresh tab, even for the same host.
        let session = SessionViewController(profile: profile, theme: theme, knownHosts: knownHosts)
        session.onTitleChanged = { [weak self] in
            self?.sessionHost.refreshTabs()
            self?.updateWindowTitle(session: self?.sessionHost.selectedSession)
        }
        session.onStateChanged = { [weak self, weak session] in
            guard let self, let session else { return }
            self.sessionHost.refreshTabs()
            self.updateSidebarStatuses()
            if session.state == .connected, self.recordedConnections.insert(session.id).inserted {
                self.hostStore.markConnected(id: profile.id)
                self.sidebarVC.refresh()
            }
            self.updateSidebarStatuses()
        }
        session.onRequestClose = { [weak self, weak session] in
            guard let self, let session else { return }
            self.closeSession(session)
        }
        session.onRequestEdit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.editHost(session.profile, session: session)
        }
        session.onRequestAISettings = {
            NotificationCenter.default.post(name: .ctermShowAISettings, object: nil)
        }
        session.onRememberSecretChanged = { [weak self, weak session] remember in
            guard let self, let session, !session.isTemporary else { return }
            var updated = session.profile
            updated.rememberSecret = remember
            self.hostStore.update(updated)
        }

        sessionHost.addSession(session)
        sessionHost.view.layoutSubtreeIfNeeded()
        DispatchQueue.main.async {
            session.startIfNeeded()
        }
        updateSidebarStatuses()
        if !profile.isTemporary {
            sidebarVC.selectHost(id: profile.id)
        }
        updateWindowTitle(session: session)
    }

    // MARK: - Session actions

    @objc func closeTab(_ sender: Any?) {
        guard sessionHost.selectedIndex >= 0 else {
            window?.performClose(sender)
            return
        }
        closeSession(at: sessionHost.selectedIndex)
    }

    @objc func closeWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc func reconnectCurrent(_ sender: Any?) {
        sessionHost.selectedSession?.reconnect()
    }

    @objc func disconnectCurrent(_ sender: Any?) {
        sessionHost.selectedSession?.disconnect()
    }

    @objc func nextTab(_ sender: Any?) {
        guard !sessionHost.sessions.isEmpty else { return }
        let next = (sessionHost.selectedIndex + 1) % sessionHost.sessions.count
        sessionHost.selectSession(at: next)
    }

    @objc func previousTab(_ sender: Any?) {
        guard !sessionHost.sessions.isEmpty else { return }
        let previous = (sessionHost.selectedIndex - 1 + sessionHost.sessions.count) % sessionHost.sessions.count
        sessionHost.selectSession(at: previous)
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let index = item.tag - 1
        guard index >= 0, index < sessionHost.sessions.count else { return }
        sessionHost.selectSession(at: index)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        rootVC.toggleSidebar()
    }

    @objc func toggleSFTPPanel(_ sender: Any?) {
        sessionHost.selectedSession?.toggleSFTPPanel()
    }

    @objc func toggleAIMode(_ sender: Any?) {
        guard let session = sessionHost.selectedSession else {
            NSSound.beep()
            return
        }
        session.toggleAIMode()
    }

    private func closeSession(at index: Int) {
        guard index >= 0, index < sessionHost.sessions.count else { return }
        let session = sessionHost.sessions[index]
        if session.hasActiveTransfers, let window {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "关闭“\(session.tabTitle)”？"
            alert.informativeText = "这个标签还有正在进行的 SFTP 传输，关闭后会被取消。"
            alert.addButton(withTitle: "关闭并取消传输")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self, weak session] response in
                guard response == .alertFirstButtonReturn, let self, let session,
                      let current = self.sessionHost.sessions.firstIndex(where: { $0.id == session.id }) else { return }
                self.removeSession(at: current)
            }
            return
        }
        removeSession(at: index)
    }

    private func removeSession(at index: Int) {
        sessionHost.removeSession(at: index)
        updateSidebarStatuses()
        updateWindowTitle(session: sessionHost.selectedSession)
    }

    private func closeSession(_ session: SessionViewController) {
        guard let index = sessionHost.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        closeSession(at: index)
    }

    private func closeOtherSessions(keeping index: Int) {
        guard index >= 0, index < sessionHost.sessions.count else { return }
        let keepID = sessionHost.sessions[index].id
        let closing = sessionHost.sessions.filter { $0.id != keepID }
        for current in closing {
            if let idx = sessionHost.sessions.firstIndex(where: { $0.id == current.id }) {
                sessionHost.removeSession(at: idx)
            }
        }
        if let keepIndex = sessionHost.sessions.firstIndex(where: { $0.id == keepID }) {
            sessionHost.selectSession(at: keepIndex)
        }
        updateSidebarStatuses()
        updateWindowTitle(session: sessionHost.selectedSession)
    }

    private func updateSidebarStatuses() {
        var statuses: [UUID: SessionTabItem.State] = [:]
        func merge(_ id: UUID, _ state: SessionTabItem.State) {
            if let existing = statuses[id] {
                let priority: [SessionTabItem.State: Int] = [.connected: 3, .connecting: 2, .failed: 1, .disconnected: 0]
                if (priority[state] ?? 0) > (priority[existing] ?? 0) {
                    statuses[id] = state
                }
            } else {
                statuses[id] = state
            }
        }
        for session in sessionHost.sessions where !session.isTemporary {
            merge(session.profile.id, session.tabState)
        }
        sidebarVC.setStatuses(statuses)
    }

    private func updateWindowTitle(session: SessionViewController?) {
        if let session {
            window?.title = "\(session.tabTitle) — cTerm"
        } else {
            window?.title = "cTerm"
        }
    }

    // MARK: - Demo / shutdown (used by snapshot and tests)

    @discardableResult
    func addDemoSession(profile: HostProfile, transcript: String, remoteTitle: String) -> SessionViewController {
        let session = SessionViewController(
            profile: profile,
            theme: theme,
            knownHosts: knownHosts,
            fontSize: 13
        )
        session.enableDemoMode()
        session.onTitleChanged = { [weak self] in
            self?.sessionHost.refreshTabs()
            self?.updateWindowTitle(session: self?.sessionHost.selectedSession)
        }
        session.onStateChanged = { [weak self] in
            self?.sessionHost.refreshTabs()
        }
        sessionHost.addSession(session)
        sessionHost.view.layoutSubtreeIfNeeded()
        session.loadDemoTranscript(transcript, remoteTitle: remoteTitle)
        updateSidebarStatuses()
        return session
    }

    func selectSidebarHost(id: UUID) {
        sidebarVC.selectHost(id: id)
    }

    func selectDemoSession(id: UUID) {
        _ = sessionHost.selectSession(id: id)
    }

    #if DEBUG
    func debugOpenSession(profile: HostProfile) {
        openSession(profile: profile)
    }

    var debugSplitDescription: String { sessionHost.debugSplitDescription }
    var debugSessionHost: SessionHostViewController { sessionHost }

    var debugSFTPPanel: SFTPPanelViewController? {
        sessionHost.selectedSession?.sftpPanel
    }

    var debugSelectedSession: SessionViewController? {
        sessionHost.selectedSession
    }
    #endif

    func shutdown() {
        for session in sessionHost.sessions {
            session.prepareForClose()
        }
        hostStore.onChange = nil
    }

    // MARK: - Theme

    @objc private func themePreferenceChanged(_ note: Notification) {
        applyTheme(AppearancePreferences.theme)
    }

    @objc private func fontPreferenceChanged(_ note: Notification) {
        sessionHost.applyFontSize()
    }

    @objc private func applicationDidBecomeActive(_ note: Notification) {
        refreshThemeFromSystemIfNeeded()
    }

    private func systemAppearanceDidChange() {
        guard !ignoresSystemAppearance, AppearancePreferences.followsSystemAppearance else { return }
        // Give AppKit a beat to update NSApplication.effectiveAppearance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshThemeFromSystemIfNeeded(force: true)
        }
    }

    private func refreshThemeFromSystemIfNeeded(force: Bool = false) {
        guard !ignoresSystemAppearance, AppearancePreferences.followsSystemAppearance else { return }
        let systemTheme = AppearancePreferences.systemTheme
        guard force || systemTheme.id != theme.id else { return }
        NotificationCenter.default.post(name: .ctermThemeDidChange, object: systemTheme)
    }

    private func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = .clear
        rootVC.apply(theme: theme)
    }

    // MARK: - Window delegate

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard hasCompletedInitialPresentation, !isApplyingWindowSize else { return frameSize }
        // With .fullSizeContentView the root view spans the full window frame,
        // so the proposed frame size is the content size used by our constraints.
        syncContentSizeConstraints(to: frameSize, save: false)
        return frameSize
    }

    func windowDidResize(_ notification: Notification) {
        guard hasCompletedInitialPresentation, let window else { return }
        let size = window.contentView?.bounds.size ?? window.frame.size
        syncContentSizeConstraints(to: size, save: true)
    }

    func windowWillClose(_ notification: Notification) {
        shutdown()
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeTab(_:)):
            return true
        case #selector(reconnectCurrent(_:)), #selector(disconnectCurrent(_:)):
            return sessionHost.selectedSession != nil
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return sessionHost.sessions.count > 1
        case #selector(selectTabByNumber(_:)):
            return menuItem.tag - 1 < sessionHost.sessions.count
        case #selector(toggleAIMode(_:)):
            menuItem.title = sessionHost.selectedSession?.isAIModeOn == true ? "退出 AI 模式" : "进入 AI 模式"
            return sessionHost.selectedSession != nil
        case #selector(toggleSFTPPanel(_:)):
            let session = sessionHost.selectedSession
            menuItem.title = session?.isSFTPPanelVisible == true ? "隐藏 SFTP 文件" : "显示 SFTP 文件"
            return session?.supportsSFTP == true
        case #selector(toggleSidebar(_:)):
            menuItem.title = rootVC.isSidebarCollapsed ? "显示侧边栏" : "隐藏侧边栏"
            return true
        default:
            return true
        }
    }
}

// MARK: - Sidebar delegate

extension MainWindowController: SidebarViewControllerDelegate {
    func sidebarDidRequestNewHost(_ sidebar: SidebarViewController) {
        showNewHost()
    }

    func sidebar(_ sidebar: SidebarViewController, newHostInGroup groupID: UUID?) {
        showNewHost(inGroup: groupID)
    }

    func sidebar(_ sidebar: SidebarViewController, connect profile: HostProfile) {
        openSession(profile: profile)
    }

    func sidebar(_ sidebar: SidebarViewController, edit profile: HostProfile) {
        editHost(profile, session: sessionHost.sessions.first(where: { $0.profile.id == profile.id }))
    }

    func sidebar(_ sidebar: SidebarViewController, delete profile: HostProfile) {
        deleteHost(profile)
    }

    func sidebar(_ sidebar: SidebarViewController, selectionChanged profile: HostProfile?) {
        _ = profile
    }
}

// MARK: - Session host delegate

extension MainWindowController: SessionHostViewControllerDelegate {
    func sessionHost(_ host: SessionHostViewController, didClose index: Int) {
        closeSession(at: index)
    }

    func sessionHost(_ host: SessionHostViewController, didRequestReconnect index: Int) {
        guard index >= 0, index < host.sessions.count else { return }
        host.sessions[index].reconnect()
    }

    func sessionHost(_ host: SessionHostViewController, didRequestCloseOthers index: Int) {
        closeOtherSessions(keeping: index)
    }

    func sessionHostDidRequestQuickConnect(_ host: SessionHostViewController) {
        showQuickConnect()
    }

    /// The tab bar's + always opens a local terminal: what it did before
    /// (a second session to the host selected in the sidebar, or quick connect
    /// when none was) depended on a selection the user could not see there.
    func sessionHostDidRequestNewTab(_ host: SessionHostViewController) {
        newLocalTerminal(nil)
    }
}