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

        tabsView.delegate = self
        tabsView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabsView)

        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(container)

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
            tabsView.topAnchor.constraint(equalTo: root.topAnchor),
            tabsView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabsView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: tabsView.bottomAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
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
        tabsView.update(items: items, selectedIndex: selectedIndex, theme: theme)
        tabsView.isHidden = false
        welcomeVC.view.isHidden = !items.isEmpty
    }

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
}
