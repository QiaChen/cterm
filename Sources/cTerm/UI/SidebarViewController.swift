import AppKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarDidRequestNewHost(_ sidebar: SidebarViewController)
    func sidebar(_ sidebar: SidebarViewController, newHostInGroup groupID: UUID?)
    func sidebar(_ sidebar: SidebarViewController, connect profile: HostProfile)
    func sidebar(_ sidebar: SidebarViewController, edit profile: HostProfile)
    func sidebar(_ sidebar: SidebarViewController, delete profile: HostProfile)
    func sidebar(_ sidebar: SidebarViewController, selectionChanged profile: HostProfile?)
}

extension NSPasteboard.PasteboardType {
    static let ctermHostID = NSPasteboard.PasteboardType("me.cqq.cterm.host-id")
}

// MARK: - Outline nodes

final class SidebarGroupNode {
    let id: UUID?
    let name: String
    var hosts: [SidebarHostNode]
    let key: String
    var isUngrouped: Bool { id == nil }

    init(id: UUID?, name: String, hosts: [SidebarHostNode]) {
        self.id = id
        self.name = name
        self.hosts = hosts
        self.key = id?.uuidString ?? "__ungrouped__"
    }
}

final class SidebarHostNode {
    let profile: HostProfile
    weak var group: SidebarGroupNode?

    init(profile: HostProfile) {
        self.profile = profile
    }
}

// MARK: - Sidebar

final class SidebarViewController: NSViewController {
    weak var delegate: SidebarViewControllerDelegate?

    private let hostStore: HostStore
    private var theme: TerminalTheme
    private var searchText = ""
    private var statuses: [UUID: SessionTabItem.State] = [:]
    private var groupNodes: [SidebarGroupNode] = []
    private var collapsedGroupKeys: Set<String>
    private var isReloading = false
    private var isTogglingGroup = false
    private var contextGroup: SidebarGroupNode?
    private var contextHost: HostProfile?

    private let glass = GlassBackgroundView()
    private let borderView: ColorView
    private let topDrag = WindowDragView()
    private let headerIcon: SymbolBadgeView
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let addGroupButton: ChromeButton
    private let addButton: ChromeButton
    private let searchContainer: RoundedCardView
    private let searchIcon = NSImageView()
    private let searchField = NSTextField()
    private let clearButton = HandCursorButton()
    private let sectionLabel: NSTextField
    private let countLabel: NSTextField
    private let scrollView = NSScrollView()
    private let outlineView = SidebarOutlineView()
    private let emptyView = NSStackView()
    private let emptyIcon: SymbolBadgeView
    private let emptyTitle: NSTextField
    private let emptySubtitle: NSTextField
    private let emptyButton: ChromeButton
    private let syncStatusView: SyncStatusView
    /// Shown instead of the sidebar while it is collapsed; laid out by the root view.
    let railView: SidebarRailView
    private var syncClockTimer: Timer?

    init(hostStore: HostStore, theme: TerminalTheme) {
        self.hostStore = hostStore
        self.theme = theme
        let stored = UserDefaults.standard.stringArray(forKey: "cterm.collapsedGroups") ?? []
        collapsedGroupKeys = Set(stored)
        borderView = ColorView(color: theme.sidebarDivider)
        headerIcon = SymbolBadgeView(
            symbol: "terminal.fill",
            background: theme.accent.withAlphaComponent(0.18),
            tint: theme.accent,
            size: 30
        )
        titleLabel = UIFactory.label("cTerm", size: 17, weight: .bold, color: theme.tabText)
        subtitleLabel = UIFactory.label("SSH 工作台", size: 11, weight: .medium, color: theme.subtle)
        addGroupButton = ChromeButton(shape: .circle, symbol: "folder.badge.plus", target: nil, action: nil)
        addButton = ChromeButton(shape: .circle, symbol: "plus", target: nil, action: nil)
        searchContainer = RoundedCardView(fill: theme.pillFill, border: theme.pillBorder, radius: 9)
        sectionLabel = UIFactory.label("主机", size: 11, weight: .semibold, color: theme.subtle)
        countLabel = UIFactory.label("", size: 11, weight: .medium, color: theme.subtle, alignment: .right)
        emptyIcon = SymbolBadgeView(
            symbol: "server.rack",
            background: theme.accent.withAlphaComponent(0.12),
            tint: theme.accent,
            size: 54
        )
        emptyTitle = UIFactory.label("还没有主机", size: 14, weight: .semibold, color: theme.tabText, alignment: .center)
        emptySubtitle = UIFactory.wrappingLabel(
            "用右上角的 + 添加服务器，或按 ⌘N 快速连接。",
            size: 12,
            color: theme.subtle
        )
        emptyButton = ChromeButton(shape: .pill, title: "添加主机", target: nil, action: nil)
        syncStatusView = SyncStatusView(theme: theme)
        railView = SidebarRailView(theme: theme)
        super.init(nibName: nil, bundle: nil)
        railView.onConnect = { [weak self] profile in
            guard let self else { return }
            self.delegate?.sidebar(self, connect: profile)
        }
        railView.onNewHost = { [weak self] in
            guard let self else { return }
            self.delegate?.sidebarDidRequestNewHost(self)
        }
        railView.onQuickConnect = { [weak self] in
            NSApp.sendAction(#selector(MainWindowController.newConnection(_:)), to: nil, from: self)
        }
        railView.onSyncClick = { [weak self] in
            self?.syncStatusClicked()
        }
        railView.update(syncStatus: CloudSyncManager.shared.currentStatus)
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncStatusChanged),
            name: .ctermSyncStatusDidChange, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        syncClockTimer?.invalidate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root

        root.addSubview(glass)
        root.addSubview(borderView)
        root.addSubview(topDrag)

        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0
        titles.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerIcon)
        root.addSubview(titles)
        root.addSubview(addGroupButton)
        root.addSubview(addButton)

        addGroupButton.target = self
        addGroupButton.action = #selector(newGroupPressed)
        addGroupButton.toolTip = "新建分组"
        addButton.target = self
        addButton.action = #selector(newHostPressed)
        addButton.toolTip = "新建主机"

        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchContainer)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.contentTintColor = theme.subtle
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(searchIcon)

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.textColor = theme.tabText
        searchField.usesSingleLineMode = true
        searchField.lineBreakMode = .byTruncatingTail
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.placeholderAttributedString = NSAttributedString(
            string: "搜索主机或分组",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.subtle]
        )
        searchContainer.addSubview(searchField)

        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清除搜索")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.contentTintColor = theme.subtle
        clearButton.target = self
        clearButton.action = #selector(clearSearch)
        clearButton.isHidden = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(clearButton)

        let sectionRow = NSStackView(views: [sectionLabel, NSView(), countLabel])
        sectionRow.orientation = .horizontal
        sectionRow.alignment = .centerY
        sectionRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sectionRow)

        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.focusRingType = .none
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.style = .plain
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineDoubleClicked)
        outlineView.indentationPerLevel = 0
        outlineView.floatsGroupRows = false
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.autoresizingMask = [.width]
        outlineView.rowHeight = 64
        outlineView.intercellSpacing = .zero
        outlineView.gridStyleMask = []
        outlineView.usesAutomaticRowHeights = false
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.registerForDraggedTypes([.ctermHostID])
        outlineView.onMenuForItem = { [weak self] item in
            self?.menu(for: item)
        }
        outlineView.onReturn = { [weak self] in
            self?.connectSelected()
        }
        outlineView.onDelete = { [weak self] in
            self?.deleteSelected()
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        column.resizingMask = .autoresizingMask
        column.width = 250
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 10, right: 0)
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        emptyTitle.alignment = .center
        emptySubtitle.alignment = .center
        emptyButton.target = self
        emptyButton.action = #selector(newHostPressed)
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 5
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addArrangedSubview(emptyIcon)
        emptyView.addArrangedSubview(emptyTitle)
        emptyView.addArrangedSubview(emptySubtitle)
        emptyView.addArrangedSubview(emptyButton)
        emptyView.setCustomSpacing(10, after: emptyIcon)
        emptyView.setCustomSpacing(12, after: emptySubtitle)
        root.addSubview(emptyView)


        syncStatusView.onClick = { [weak self] in
            self?.syncStatusClicked()
        }
        root.addSubview(syncStatusView)
        // Keeps "3 分钟前" current.
        syncClockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.syncStatusChanged()
        }

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glass.topAnchor.constraint(equalTo: root.topAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            borderView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            borderView.topAnchor.constraint(equalTo: root.topAnchor),
            borderView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            borderView.widthAnchor.constraint(equalToConstant: 1),

            topDrag.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDrag.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topDrag.topAnchor.constraint(equalTo: root.topAnchor),
            topDrag.heightAnchor.constraint(equalToConstant: 52),

            headerIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            headerIcon.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            headerIcon.widthAnchor.constraint(equalToConstant: 30),
            headerIcon.heightAnchor.constraint(equalToConstant: 30),
            titles.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 9),
            titles.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: addGroupButton.leadingAnchor, constant: -8),
            addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            addButton.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 26),
            addButton.heightAnchor.constraint(equalToConstant: 26),
            addGroupButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -6),
            addGroupButton.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            addGroupButton.widthAnchor.constraint(equalToConstant: 26),
            addGroupButton.heightAnchor.constraint(equalToConstant: 26),

            searchContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            searchContainer.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: 16),
            searchContainer.heightAnchor.constraint(equalToConstant: 34),
            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 11),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 13),
            searchIcon.heightAnchor.constraint(equalToConstant: 13),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 7),
            searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 18),
            clearButton.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),

            sectionRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            sectionRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            sectionRow.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 17),
            sectionRow.heightAnchor.constraint(equalToConstant: 16),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: sectionRow.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: syncStatusView.topAnchor, constant: -10),

            syncStatusView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            syncStatusView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            syncStatusView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            syncStatusView.heightAnchor.constraint(equalToConstant: 34),

            emptyView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -14),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 28),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            emptySubtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 205),
            emptyIcon.widthAnchor.constraint(equalToConstant: 54),
            emptyIcon.heightAnchor.constraint(equalToConstant: 54),
            emptyButton.widthAnchor.constraint(equalToConstant: 104),
            emptyButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        apply(theme: theme)
        refresh()
        if let first = groupNodes.first(where: { !$0.hosts.isEmpty })?.hosts.first {
            selectHost(id: first.profile.id)
        }
    }


    func apply(theme: TerminalTheme) {
        self.theme = theme
        glass.apply(
            theme: theme,
            material: .sidebar,
            topAlpha: theme.isDark ? 0.52 : 0.40,
            bottomAlpha: theme.isDark ? 0.68 : 0.50,
            accentGlow: true
        )
        borderView.color = theme.sidebarDivider
        titleLabel.textColor = theme.tabText
        subtitleLabel.textColor = theme.subtle
        sectionLabel.textColor = theme.subtle
        countLabel.textColor = theme.subtle

        headerIcon.apply(
            background: theme.accent.withAlphaComponent(0.18),
            tint: theme.accent,
            symbol: "terminal.fill"
        )
        addButton.fillColor = theme.pillFill
        addButton.hoverFillColor = theme.pillHoverFill
        addButton.borderColor = .clear
        addButton.titleColor = theme.tabText
        addButton.needsDisplay = true
        addGroupButton.fillColor = theme.pillFill
        addGroupButton.hoverFillColor = theme.pillHoverFill
        addGroupButton.borderColor = .clear
        addGroupButton.titleColor = theme.tabText
        addGroupButton.needsDisplay = true

        searchContainer.fillColor = theme.pillFill
        searchContainer.borderColor = theme.pillBorder
        searchIcon.contentTintColor = theme.subtle
        searchField.textColor = theme.tabText
        searchField.placeholderAttributedString = NSAttributedString(
            string: "搜索主机或分组",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.subtle]
        )
        clearButton.contentTintColor = theme.subtle

        emptyIcon.apply(
            background: theme.accent.withAlphaComponent(0.12),
            tint: theme.accent,
            symbol: "server.rack"
        )
        emptyTitle.textColor = theme.tabText
        emptySubtitle.textColor = theme.subtle
        emptyButton.fillColor = theme.accent
        emptyButton.hoverFillColor = theme.accent.blended(withFraction: 0.15, of: .white) ?? theme.accent
        emptyButton.borderColor = .clear
        emptyButton.titleColor = .white
        emptyButton.needsDisplay = true

        syncStatusView.apply(theme: theme)
        railView.apply(theme: theme)

        if outlineView.numberOfRows > 0 {
            reloadOutline(preserveSelection: true)
        }
        view.needsDisplay = true
    }

    func refresh() {
        reloadOutline(preserveSelection: true)
    }

    @objc private func syncStatusChanged() {
        syncStatusView.update(status: CloudSyncManager.shared.currentStatus)
        railView.update(syncStatus: CloudSyncManager.shared.currentStatus)
    }

    private func syncStatusClicked() {
        let manager = CloudSyncManager.shared
        if manager.isEnabled {
            manager.syncSoon(delay: 0)
        } else {
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: self)
        }
    }

    func setStatuses(_ statuses: [UUID: SessionTabItem.State]) {
        self.statuses = statuses
        reloadOutline(preserveSelection: true)
    }

    func selectHost(id: UUID) {
        guard let initial = allHostNodes.first(where: { $0.profile.id == id }) else { return }
        if let group = initial.group, isGroupCollapsed(group) {
            collapsedGroupKeys.remove(group.key)
            saveCollapsedGroups()
            reloadOutline(preserveSelection: false)
        }
        guard let hostNode = allHostNodes.first(where: { $0.profile.id == id }) else { return }
        let row = outlineView.row(forItem: hostNode)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    var selectedProfile: HostProfile? {
        guard outlineView.selectedRow >= 0,
              let host = outlineView.item(atRow: outlineView.selectedRow) as? SidebarHostNode else {
            return nil
        }
        return host.profile
    }

    private var allHostNodes: [SidebarHostNode] {
        groupNodes.flatMap(\.hosts)
    }

    // MARK: - Building

    private var searchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isGroupCollapsed(_ group: SidebarGroupNode) -> Bool {
        !searchActive && collapsedGroupKeys.contains(group.key)
    }

    private func reloadOutline(preserveSelection: Bool) {
        let selectedID = preserveSelection ? selectedProfile?.id : nil
        isReloading = true
        buildNodes()
        outlineView.reloadData()

        for group in groupNodes where !group.hosts.isEmpty {
            // The data source hides children for collapsed groups; we keep the
            // outline's internal expansion true so open groups can appear without
            // relying on NSOutlineView's animated collapse behavior.
            outlineView.expandItem(group)
        }

        for group in groupNodes {
            let row = outlineView.row(forItem: group)
            if row >= 0 {
                outlineView.reloadData(
                    forRowIndexes: IndexSet(integer: row),
                    columnIndexes: IndexSet(integer: 0)
                )
            }
        }
        if let selectedID, let host = allHostNodes.first(where: { $0.profile.id == selectedID }) {
            let row = outlineView.row(forItem: host)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                outlineView.deselectAll(nil)
            }
        } else {
            outlineView.deselectAll(nil)
        }
        isReloading = false

        updateRail()
        let hostCount = allHostNodes.count
        countLabel.stringValue = "\(hostCount)"
        if groupNodes.isEmpty {
            emptyTitle.stringValue = searchActive ? "没有匹配的主机" : "还没有主机"
            emptySubtitle.stringValue = searchActive
                ? "试试其他关键词，或新建一台主机。"
                : "用右上角的 + 添加服务器，或按 ⌘N 快速连接。"
            emptyView.isHidden = false
            outlineView.deselectAll(nil)
        } else {
            emptyView.isHidden = true
        }
    }

    /// The rail always lists every group, whatever the search field holds.
    private func updateRail() {
        var groups = hostStore.groups.map {
            SidebarRailView.Group(id: $0.id, name: $0.displayName, hosts: hostStore.hosts(inGroup: $0.id))
        }
        let ungrouped = hostStore.ungroupedHosts
        if !ungrouped.isEmpty || groups.isEmpty {
            groups.append(SidebarRailView.Group(id: nil, name: "未分组", hosts: ungrouped))
        }
        railView.update(groups: groups, statuses: statuses, selectedHostID: selectedProfile?.id)
    }

    private func buildNodes() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var nodes: [SidebarGroupNode] = []

        for group in hostStore.groups {
            let allHosts = hostStore.hosts(inGroup: group.id)
            let groupMatches = !query.isEmpty && group.displayName.lowercased().contains(query)
            let matchingHosts = allHosts.filter { matches($0, query: query) }
            if query.isEmpty || groupMatches || !matchingHosts.isEmpty {
                let visible = (query.isEmpty || groupMatches) ? allHosts : matchingHosts
                nodes.append(makeGroupNode(id: group.id, name: group.displayName, profiles: visible))
            }
        }

        let ungrouped = hostStore.ungroupedHosts
        if query.isEmpty {
            if !ungrouped.isEmpty || !hostStore.groups.isEmpty {
                nodes.append(makeGroupNode(id: nil, name: "未分组", profiles: ungrouped))
            }
        } else {
            let matching = ungrouped.filter { matches($0, query: query) }
            if !matching.isEmpty {
                nodes.append(makeGroupNode(id: nil, name: "未分组", profiles: matching))
            }
        }
        groupNodes = nodes
    }

    private func matches(_ profile: HostProfile, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return profile.displayName.lowercased().contains(query)
            || profile.host.lowercased().contains(query)
            || profile.username.lowercased().contains(query)
            || profile.notes.lowercased().contains(query)
    }

    private func makeGroupNode(id: UUID?, name: String, profiles: [HostProfile]) -> SidebarGroupNode {
        let hosts = profiles.map { SidebarHostNode(profile: $0) }
        let node = SidebarGroupNode(id: id, name: name, hosts: hosts)
        for host in hosts { host.group = node }
        return node
    }

    private func saveCollapsedGroups() {
        UserDefaults.standard.set(Array(collapsedGroupKeys), forKey: "cterm.collapsedGroups")
    }

    private func toggleGroup(_ group: SidebarGroupNode) {
        guard !group.hosts.isEmpty else { return }
        outlineView.deselectAll(nil)
        if isGroupCollapsed(group) {
            collapsedGroupKeys.remove(group.key)
        } else {
            collapsedGroupKeys.insert(group.key)
        }
        saveCollapsedGroups()
        reloadOutline(preserveSelection: false)
    }

    // MARK: - Search

    @objc private func clearSearch() {
        searchText = ""
        searchField.stringValue = ""
        clearButton.isHidden = true
        reloadOutline(preserveSelection: true)
    }

    // MARK: - Actions

    @objc private func newHostPressed() {
        delegate?.sidebarDidRequestNewHost(self)
    }

    @objc private func outlineDoubleClicked() {
        guard outlineView.clickedRow >= 0,
              let host = outlineView.item(atRow: outlineView.clickedRow) as? SidebarHostNode else { return }
        delegate?.sidebar(self, connect: host.profile)
    }

    private func connectSelected() {
        guard let profile = selectedProfile else { return }
        delegate?.sidebar(self, connect: profile)
    }

    private func deleteSelected() {
        guard let profile = selectedProfile else { return }
        delegate?.sidebar(self, delete: profile)
    }

    @objc private func newGroupPressed() {
        createGroup()
    }

    private func createGroup() {
        promptGroupName(title: "新建分组", message: "为服务器创建一个分组。", initial: "") { [weak self] name in
            guard let self, let name else { return }
            guard let group = self.hostStore.addGroup(named: name) else {
                self.showAlert(title: "无法新建分组", message: "分组名称不能为空，也不能与现有分组重复。")
                return
            }
            self.reloadOutline(preserveSelection: true)
            if let node = self.groupNodes.first(where: { $0.id == group.id }) {
                let row = self.outlineView.row(forItem: node)
                if row >= 0 { self.outlineView.scrollRowToVisible(row) }
            }
        }
    }

    private func renameGroup(_ group: SidebarGroupNode) {
        guard let id = group.id else { return }
        promptGroupName(title: "重命名分组", message: "输入新的分组名称。", initial: group.name) { [weak self] name in
            guard let self, let name else { return }
            guard self.hostStore.renameGroup(id: id, to: name) else {
                self.showAlert(title: "无法重命名", message: "分组名称不能为空，也不能与现有分组重复。")
                return
            }
            self.reloadOutline(preserveSelection: true)
        }
    }

    private func deleteGroup(_ group: SidebarGroupNode) {
        guard let id = group.id, let window = view.window else { return }
        let count = hostStore.hosts(inGroup: id).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除分组“\(group.name)”？"
        alert.informativeText = count == 0
            ? "该分组为空。"
            : "分组内的 \(count) 台主机将移动到“未分组”，不会被删除。"
        alert.addButton(withTitle: "删除分组")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.hostStore.deleteGroup(id: id)
            self.reloadOutline(preserveSelection: true)
        }
    }

    private func promptGroupName(title: String, message: String, initial: String,
                                 completion: @escaping (String?) -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        field.placeholderString = "分组名称"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(value.isEmpty ? nil : value)
        }
    }

    private func showAlert(title: String, message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    // MARK: - Context menus

    private func menuItem(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func menu(for item: Any?) -> NSMenu? {
        contextGroup = nil
        contextHost = nil
        let menu = NSMenu()

        if let group = item as? SidebarGroupNode {
            contextGroup = group
            menu.addItem(menuItem("在此分组中新建主机…", action: #selector(newHostInContextGroup)))
            if !group.hosts.isEmpty {
                menu.addItem(menuItem(
                    isGroupCollapsed(group) ? "展开分组" : "折叠分组",
                    action: #selector(toggleContextGroup)
                ))
            }
            if !group.isUngrouped {
                menu.addItem(.separator())
                menu.addItem(menuItem("重命名分组…", action: #selector(renameContextGroup)))
                menu.addItem(menuItem("删除分组…", action: #selector(deleteContextGroup)))
            }
            return menu
        }

        if let host = item as? SidebarHostNode {
            contextHost = host.profile
            menu.addItem(menuItem("在新标签页中连接", action: #selector(connectContextHost)))
            menu.addItem(menuItem("编辑主机…", action: #selector(editContextHost)))
            let move = NSMenuItem(title: "移动到分组", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let ungrouped = menuItem("未分组", action: #selector(moveContextHost))
            ungrouped.representedObject = ""
            ungrouped.state = host.profile.groupID == nil ? .on : .off
            submenu.addItem(ungrouped)
            for group in hostStore.groups {
                let item = menuItem(group.displayName, action: #selector(moveContextHost))
                item.representedObject = group.id.uuidString
                item.state = host.profile.groupID == group.id ? .on : .off
                submenu.addItem(item)
            }
            move.submenu = submenu
            menu.addItem(move)
            menu.addItem(.separator())
            menu.addItem(menuItem("复制连接信息", action: #selector(copyContextHost)))
            menu.addItem(menuItem("删除主机…", action: #selector(deleteContextHost)))
            return menu
        }

        menu.addItem(menuItem("新建主机…", action: #selector(newHostFromMenu)))
        menu.addItem(menuItem("新建分组…", action: #selector(newGroupFromMenu)))
        return menu
    }

    @objc private func newHostInContextGroup() {
        delegate?.sidebar(self, newHostInGroup: contextGroup?.id)
    }

    @objc private func newHostFromMenu() {
        delegate?.sidebarDidRequestNewHost(self)
    }

    @objc private func newGroupFromMenu() {
        createGroup()
    }

    @objc private func toggleContextGroup() {
        guard let group = contextGroup else { return }
        toggleGroup(group)
    }

    @objc private func renameContextGroup() {
        guard let group = contextGroup else { return }
        renameGroup(group)
    }

    @objc private func deleteContextGroup() {
        guard let group = contextGroup else { return }
        deleteGroup(group)
    }

    @objc private func connectContextHost() {
        guard let profile = contextHost else { return }
        delegate?.sidebar(self, connect: profile)
    }

    @objc private func editContextHost() {
        guard let profile = contextHost else { return }
        delegate?.sidebar(self, edit: profile)
    }

    @objc private func deleteContextHost() {
        guard let profile = contextHost else { return }
        delegate?.sidebar(self, delete: profile)
    }

    @objc private func copyContextHost() {
        guard let profile = contextHost else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(profile.endpoint, forType: .string)
    }

    @objc private func moveContextHost(_ sender: NSMenuItem) {
        guard let profile = contextHost else { return }
        let target: UUID?
        if let raw = sender.representedObject as? String, !raw.isEmpty {
            target = UUID(uuidString: raw)
        } else {
            target = nil
        }
        hostStore.setGroup(target, for: profile.id)
        expandGroup(id: target)
        selectHost(id: profile.id)
        reloadOutline(preserveSelection: true)
    }

    private func expandGroup(id: UUID?) {
        guard let node = groupNodes.first(where: { $0.id == id }) else { return }
        collapsedGroupKeys.remove(node.key)
        saveCollapsedGroups()
        reloadOutline(preserveSelection: false)
    }
}

// MARK: - Search delegate

extension SidebarViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchText = searchField.stringValue
        clearButton.isHidden = searchText.isEmpty
        reloadOutline(preserveSelection: true)
    }
}

// MARK: - Outline data source

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groupNodes.count }
        if let group = item as? SidebarGroupNode {
            return isGroupCollapsed(group) ? 0 : group.hosts.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groupNodes[index] }
        if let group = item as? SidebarGroupNode { return group.hosts[index] }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let group = item as? SidebarGroupNode {
            return !group.hosts.isEmpty
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let host = item as? SidebarHostNode else { return nil }
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(host.profile.id.uuidString, forType: .ctermHostID)
        return pasteboard
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: .ctermHostID) != nil else { return [] }
        if item is SidebarGroupNode {
            return .move
        }
        if let host = item as? SidebarHostNode, let group = host.group {
            outlineView.setDropItem(group, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        if let ungrouped = groupNodes.first(where: { $0.isUngrouped }) {
            outlineView.setDropItem(ungrouped, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: .ctermHostID),
              let id = UUID(uuidString: raw) else { return false }
        let target: SidebarGroupNode?
        if let group = item as? SidebarGroupNode {
            target = group
        } else if let host = item as? SidebarHostNode {
            target = host.group
        } else {
            target = groupNodes.first(where: { $0.isUngrouped })
        }
        guard let target else { return false }
        hostStore.setGroup(target.id, for: id)
        collapsedGroupKeys.remove(target.key)
        saveCollapsedGroups()
        reloadOutline(preserveSelection: false)
        selectHost(id: id)
        return true
    }
}

// MARK: - Outline delegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroupNode {
            let identifier = NSUserInterfaceItemIdentifier("GroupCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? GroupCellView)
                ?? GroupCellView()
            cell.identifier = identifier
            cell.configure(
                group: group,
                expanded: !isGroupCollapsed(group),
                theme: theme
            )
            return cell
        }
        if let host = item as? SidebarHostNode {
            let identifier = NSUserInterfaceItemIdentifier("HostCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? HostCellView)
                ?? HostCellView()
            cell.identifier = identifier
            let sessionState = statuses[host.profile.id]
            let dotStatus: StatusDotView.Status
            switch sessionState {
            case .connected: dotStatus = .connected
            case .connecting: dotStatus = .connecting
            case .failed: dotStatus = .failed
            case .disconnected, .none: dotStatus = .idle
            }
            cell.configure(profile: host.profile, status: dotStatus, theme: theme)
            return cell
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("SidebarRow")
        let row = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarRowView)
            ?? SidebarRowView()
        row.identifier = identifier
        row.theme = theme
        row.isGroupRow = item is SidebarGroupNode
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is SidebarGroupNode ? 34 : 64
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarHostNode || item is SidebarGroupNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, !isTogglingGroup else { return }
        if outlineView.isRightClickActive { return }
        guard outlineView.selectedRow >= 0,
              let group = outlineView.item(atRow: outlineView.selectedRow) as? SidebarGroupNode else {
            delegate?.sidebar(self, selectionChanged: selectedProfile)
            updateRail()
            return
        }
        isTogglingGroup = true
        toggleGroup(group)
        // The group is an action target, not a persistent selection. Clear it
        // asynchronously so the next click selects and toggles again.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.outlineView.deselectAll(nil)
            self.isTogglingGroup = false
        }
    }
}

// MARK: - Outline view

final class SidebarOutlineView: NSOutlineView {
    var onMenuForItem: ((Any?) -> NSMenu?)?
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    private(set) var isRightClickActive = false

    override func rightMouseDown(with event: NSEvent) {
        isRightClickActive = true
        super.rightMouseDown(with: event)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRightClickActive = false
            if self.selectedRow >= 0, self.item(atRow: self.selectedRow) is SidebarGroupNode {
                self.deselectAll(nil)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        let item = clicked >= 0 ? item(atRow: clicked) : nil
        return onMenuForItem?(item)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onReturn?()
        case 51, 117:
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Row and cell views

final class SidebarRowView: NSTableRowView {
    var theme: TerminalTheme = .midnight
    var isGroupRow = false
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// The selection is a light themed pill, not the system's saturated
    /// highlight, so cells keep their normal style. The emphasized style turns
    /// template icons (the key and lock) white, which vanished on the pill.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering, !isSelected else { return }
        let rect = bounds.insetBy(dx: 6, dy: 2)
        if isGroupRow {
            // pillFill already carries its own alpha; replacing that alpha with
            // withAlphaComponent(0.5) made the dark-theme hover look almost white.
            theme.pillFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        } else {
            theme.pillFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, !isGroupRow else { return }
        let rect = bounds.insetBy(dx: 6, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        theme.selectedPillFill.setFill()
        path.fill()
        theme.selectedPillBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.pointingHand.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.arrow.set()
        needsDisplay = true
    }
}

final class GroupCellView: NSTableCellView {
    private let chevron = NSImageView()
    private let folder = NSImageView()
    private let nameLabel = UIFactory.label("", size: 12, weight: .semibold, color: .secondaryLabelColor)
    private let countLabel = UIFactory.label("", size: 11, weight: .medium, color: .tertiaryLabelColor, alignment: .right)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        chevron.imageScaling = .scaleProportionallyDown
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        folder.imageScaling = .scaleProportionallyDown
        folder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(folder)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),
            folder.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            folder.centerYAnchor.constraint(equalTo: centerYAnchor),
            folder.widthAnchor.constraint(equalToConstant: 12),
            folder.heightAnchor.constraint(equalToConstant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: folder.trailingAnchor, constant: 7),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(group: SidebarGroupNode, expanded: Bool, theme: TerminalTheme) {
        let chevronName = expanded ? "chevron.down" : "chevron.right"
        chevron.image = NSImage(systemSymbolName: chevronName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        chevron.contentTintColor = theme.subtle
        chevron.isHidden = group.hosts.isEmpty
        folder.image = NSImage(
            systemSymbolName: group.isUngrouped ? "tray.fill" : "folder.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        folder.contentTintColor = theme.accent.withAlphaComponent(0.85)
        nameLabel.stringValue = group.name
        nameLabel.textColor = theme.tabInactiveText.withAlphaComponent(0.95)
        countLabel.stringValue = "\(group.hosts.count)"
        countLabel.textColor = theme.subtle.withAlphaComponent(0.85)
    }
}

final class HostCellView: NSTableCellView {
    private let avatar = HostAvatarView()
    private let nameLabel = UIFactory.label("", size: 14, weight: .semibold, color: .labelColor)
    private let endpointLabel = UIFactory.label("", size: 12, weight: .regular, color: .secondaryLabelColor)
    private let statusDot = StatusDotView()
    private let authIcon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        endpointLabel.translatesAutoresizingMaskIntoConstraints = false
        let textStack = NSStackView(views: [nameLabel, endpointLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDot)

        authIcon.imageScaling = .scaleProportionallyDown
        authIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(authIcon)

        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 34),
            avatar.heightAnchor.constraint(equalToConstant: 34),

            textStack.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: authIcon.leadingAnchor, constant: -6),

            authIcon.trailingAnchor.constraint(equalTo: statusDot.leadingAnchor, constant: -8),
            authIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            authIcon.widthAnchor.constraint(equalToConstant: 11),
            authIcon.heightAnchor.constraint(equalToConstant: 11),

            statusDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7)
        ])
    }

    func configure(profile: HostProfile, status: StatusDotView.Status, theme: TerminalTheme) {
        nameLabel.stringValue = profile.displayName
        nameLabel.textColor = theme.tabText
        endpointLabel.stringValue = profile.subtitle
        endpointLabel.textColor = theme.subtle
        statusDot.status = status
        avatar.configure(profile: profile, theme: theme)
        authIcon.image = NSImage(
            systemSymbolName: profile.auth == .privateKey ? "key.fill" : "lock.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        authIcon.contentTintColor = theme.subtle.withAlphaComponent(0.7)
        toolTip = "\(profile.displayName)\n\(profile.endpoint)"
    }
}

final class HostAvatarView: NSView {
    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.borderWidth = 1
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 17),
            imageView.heightAnchor.constraint(equalToConstant: 17)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(profile: HostProfile, theme: TerminalTheme) {
        layer?.backgroundColor = theme.accent.withAlphaComponent(0.14).cgColor
        layer?.borderColor = theme.accent.withAlphaComponent(0.24).cgColor
        imageView.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        imageView.contentTintColor = theme.accent
    }
}
