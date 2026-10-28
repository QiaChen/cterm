import AppKit

protocol SessionHostViewControllerDelegate: AnyObject {
    func sessionHost(_ host: SessionHostViewController, didClose index: Int)
    func sessionHost(_ host: SessionHostViewController, didRequestReconnect index: Int)
    func sessionHost(_ host: SessionHostViewController, didRequestCloseOthers index: Int)
    func sessionHostDidRequestQuickConnect(_ host: SessionHostViewController)
    func sessionHostDidRequestNewTab(_ host: SessionHostViewController)
}

final class SessionHostViewController: NSViewController {
    weak var delegate: SessionHostViewControllerDelegate?

    var onNewHost: (() -> Void)?
    var onQuickConnect: (() -> Void)?
    var onLocalTerminal: (() -> Void)?
    var onSelectionChanged: ((SessionViewController?) -> Void)?

    private(set) var sessions: [SessionViewController] = []
    private(set) var selectedIndex = -1
    private let tabsView: SessionTabsView
    private let contentGlass = GlassBackgroundView()
    private let container = NSView()
    /// Tabs and terminal on the left, the selected tab's SFTP panel on the
    /// right, both running the full height of the window.
    private let splitView = SessionSplitView()
    private let mainPane = NSView()
    private let sidePane = NSView()
    private var liveResizeObserver: NSObjectProtocol?
    private weak var shownPanel: SFTPPanelViewController?
    private var applyingPanelWidth = false
    private let welcomeVC: WelcomeViewController
    private var theme: TerminalTheme

    init(theme: TerminalTheme) {
        self.theme = theme
        self.tabsView = SessionTabsView(theme: theme)
        self.welcomeVC = WelcomeViewController(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root

        // One glass surface runs behind both the tab strip and the terminal, so
        // the active tab is visually continuous with its content.
        contentGlass.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentGlass)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        splitView.addArrangedSubview(mainPane)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        // The side column joins the split only while a panel is shown.

        tabsView.delegate = self
        tabsView.translatesAutoresizingMaskIntoConstraints = false
        mainPane.addSubview(tabsView)

        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        mainPane.addSubview(container)

        addChild(welcomeVC)
        welcomeVC.onNewHost = { [weak self] in self?.onNewHost?() }
        welcomeVC.onQuickConnect = { [weak self] in self?.onQuickConnect?() }
        welcomeVC.onLocalTerminal = { [weak self] in self?.onLocalTerminal?() }
        welcomeVC.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(welcomeVC.view)
        NSLayoutConstraint.activate([
            welcomeVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            welcomeVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            welcomeVC.view.topAnchor.constraint(equalTo: container.topAnchor),
            welcomeVC.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        NSLayoutConstraint.activate([
            contentGlass.topAnchor.constraint(equalTo: root.topAnchor),
            contentGlass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentGlass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentGlass.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tabsView.topAnchor.constraint(equalTo: mainPane.topAnchor),
            tabsView.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            tabsView.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            container.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            container.topAnchor.constraint(equalTo: tabsView.bottomAnchor),
            container.bottomAnchor.constraint(equalTo: mainPane.bottomAnchor)
        ])

        apply(theme: theme)
        refreshTabs()
    }

    var selectedSession: SessionViewController? {
        guard selectedIndex >= 0, selectedIndex < sessions.count else { return nil }
        return sessions[selectedIndex]
    }

    func addSession(_ session: SessionViewController) {
        sessions.append(session)
        addChild(session)
        session.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(session.view)
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            session.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            session.view.topAnchor.constraint(equalTo: container.topAnchor),
            session.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        session.view.isHidden = true
        session.onSFTPVisibilityChanged = { [weak self] in self?.refreshTabs() }
        selectSession(at: sessions.count - 1)
    }

    func removeSession(at index: Int) {
        guard index >= 0, index < sessions.count else { return }
        let session = sessions.remove(at: index)
        session.prepareForClose()
        session.view.removeFromSuperview()
        session.removeFromParent()
        if sessions.isEmpty {
            selectedIndex = -1
            refreshTabs()
            onSelectionChanged?(nil)
            return
        }
        if selectedIndex > index {
            selectedIndex -= 1
        } else if selectedIndex == index {
            selectedIndex = min(index, sessions.count - 1)
        }
        showSelected()
        refreshTabs()
        onSelectionChanged?(selectedSession)
    }

    func selectSession(at index: Int) {
        guard index >= 0, index < sessions.count else { return }
        selectedIndex = index
        showSelected()
        refreshTabs()
        onSelectionChanged?(selectedSession)
        if let window = view.window, let session = selectedSession {
            window.makeFirstResponder(session.terminalView)
        }
    }

    func selectSession(id: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        selectSession(at: index)
        return true
    }

    func refreshTabs() {
        var counts: [String: Int] = [:]
        for session in sessions {
            counts[session.tabTitle, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        let items = sessions.map { session -> SessionTabItem in
            let base = session.tabTitle
            var title = base
            if (counts[base] ?? 0) > 1 {
                let number = (seen[base] ?? 0) + 1
                seen[base] = number
                title = "\(base) · \(number)"
            }
            return SessionTabItem(id: session.id, title: title, state: session.tabState)
        }
        let sftp: SessionTabsView.SFTPButtonState
        if let session = selectedSession, session.supportsSFTP {
            sftp = session.isSFTPPanelVisible ? .active : .inactive
        } else {
            sftp = .hidden
        }
        tabsView.update(items: items, selectedIndex: selectedIndex, theme: theme, sftp: sftp)
        tabsView.isHidden = false
        welcomeVC.view.isHidden = !items.isEmpty
        refreshSidePanel()
    }

    /// Shows the selected tab's SFTP panel in the side column, or hides it.
    private func refreshSidePanel() {
        guard isViewLoaded else { return }
        // Adding or removing a pane while the user drags the window edge
        // crashes NSSplitView (adjustSubviews indexes a subview list it took
        // before the change). Wait for the drag to end.
        if isLiveResizing {
            refreshSidePanelAfterLiveResize()
            return
        }
        let session = selectedSession
        let panel = session?.isSFTPPanelVisible == true ? session?.sftpPanel : nil
        if shownPanel !== panel {
            shownPanel?.view.removeFromSuperview()
            if let panel {
                panel.view.translatesAutoresizingMaskIntoConstraints = false
                sidePane.addSubview(panel.view)
                NSLayoutConstraint.activate([
                    panel.view.leadingAnchor.constraint(equalTo: sidePane.leadingAnchor),
                    panel.view.trailingAnchor.constraint(equalTo: sidePane.trailingAnchor),
                    panel.view.topAnchor.constraint(equalTo: sidePane.topAnchor),
                    panel.view.bottomAnchor.constraint(equalTo: sidePane.bottomAnchor)
                ])
            }
            shownPanel = panel
        }
        let visible = panel != nil
        guard visible != isSidePaneShown else { return }
        if visible {
            splitView.addArrangedSubview(sidePane)
            // Window resizes go to the terminal; the panel keeps its width.
            splitView.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 1)
        } else {
            // Removed, not just hidden: a collapsed pane leaves a divider at
            // the window's right edge that a window resize can grab and pull
            // open as an empty column.
            splitView.removeArrangedSubview(sidePane)
            sidePane.removeFromSuperview()
        }
        applyPanelWidth()
        // The glass behind is transparent, so the old divider stays on
        // screen unless the split view repaints.
        splitView.needsDisplay = true
    }

    private var isSidePaneShown: Bool { sidePane.superview != nil }

    private var isLiveResizing: Bool {
        #if DEBUG
        if debugForceLiveResize { return true }
        #endif
        return view.window?.inLiveResize == true
    }

    private func refreshSidePanelAfterLiveResize() {
        guard liveResizeObserver == nil, let window = view.window else { return }
        liveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.liveResizeObserver { NotificationCenter.default.removeObserver(observer) }
                self.liveResizeObserver = nil
                self.refreshSidePanel()
            }
        }
    }

    #if DEBUG
    /// Stands in for a window-edge drag, which a test can't start.
    var debugForceLiveResize = false {
        didSet {
            guard oldValue, !debugForceLiveResize, let window = view.window else { return }
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        }
    }

    var debugSidePaneShown: Bool { isSidePaneShown }
    #endif

    #if DEBUG
    var debugSplitDescription: String {
        let panes = splitView.arrangedSubviews.map { Int($0.frame.width) }
        return "split \(Int(splitView.bounds.width)) panes \(panes) tabs \(Int(tabsView.frame.width))"
    }
    #endif

    private func showSelected() {
        for (index, session) in sessions.enumerated() {
            session.view.isHidden = index != selectedIndex
        }
        welcomeVC.view.isHidden = !sessions.isEmpty
    }

    var tabsLeadingInset: CGFloat {
        get { tabsView.leadingInset }
        set { tabsView.leadingInset = newValue }
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        view.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.backgroundColor = NSColor.clear.cgColor
        contentGlass.apply(
            theme: theme,
            material: .sidebar,
            topAlpha: theme.isDark ? 0.60 : 0.12,
            bottomAlpha: theme.isDark ? 0.74 : 0.20
        )
        tabsView.apply(theme: theme)
        splitView.dividerTint = theme.sidebarDivider
        welcomeVC.apply(theme: theme)
        sessions.forEach { $0.apply(theme: theme) }
        refreshTabs()
    }

    func applyFontSize() {
        sessions.forEach { $0.applyFontSize() }
    }

    func focusSelected() {
        guard let window = view.window, let session = selectedSession else { return }
        window.makeFirstResponder(session.terminalView)
    }
}

extension SessionHostViewController: SessionTabsViewDelegate {
    func tabsView(_ tabsView: SessionTabsView, didSelect index: Int) {
        selectSession(at: index)
    }

    func tabsView(_ tabsView: SessionTabsView, didClose index: Int) {
        delegate?.sessionHost(self, didClose: index)
    }

    func tabsViewDidRequestNewTab(_ tabsView: SessionTabsView) {
        delegate?.sessionHostDidRequestNewTab(self)
    }

    func tabsViewDidRequestQuickConnect(_ tabsView: SessionTabsView) {
        delegate?.sessionHostDidRequestQuickConnect(self)
    }

    func tabsView(_ tabsView: SessionTabsView, didRequestReconnect index: Int) {
        delegate?.sessionHost(self, didRequestReconnect: index)
    }

    func tabsView(_ tabsView: SessionTabsView, didRequestCloseOthers index: Int) {
        delegate?.sessionHost(self, didRequestCloseOthers: index)
    }

    func tabsViewDidToggleSFTP(_ tabsView: SessionTabsView) {
        selectedSession?.toggleSFTPPanel()
    }
}

// MARK: - SFTP side column

extension SessionHostViewController: NSSplitViewDelegate {
    private static let panelWidthKey = "cterm.sftpPanelWidth"
    private static let minPanelWidth: CGFloat = 240
    private static let minMainWidth: CGFloat = 360

    private static var savedPanelWidth: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: panelWidthKey)
            return value > 0 ? CGFloat(value) : 300
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: panelWidthKey) }
    }

    private func applyPanelWidth() {
        splitView.adjustSubviews()
        guard isSidePaneShown else { return }
        splitView.layoutSubtreeIfNeeded()
        let total = splitView.bounds.width
        let width = min(Self.savedPanelWidth, max(Self.minPanelWidth, total - Self.minMainWidth))
        applyingPanelWidth = true
        splitView.setPosition(total - width - splitView.dividerThickness, ofDividerAt: 0)
        applyingPanelWidth = false
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, Self.minMainWidth)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - Self.minPanelWidth - splitView.dividerThickness)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingPanelWidth, isSidePaneShown, sidePane.frame.width >= Self.minPanelWidth else { return }
        Self.savedPanelWidth = sidePane.frame.width
    }
}

/// A split view whose divider is a theme-colored hairline.
final class SessionSplitView: NSSplitView {
    var dividerTint: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }

    override var dividerColor: NSColor { dividerTint }
    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        // No hairline while a side is collapsed.
        guard arrangedSubviews.allSatisfy({ !$0.isHidden }) else { return }
        super.drawDivider(in: rect)
    }
}
