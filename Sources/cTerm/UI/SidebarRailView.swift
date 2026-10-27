import AppKit

/// The collapsed sidebar: a narrow column with one icon per host group.
/// Clicking a group lists its hosts beside the icon; picking one connects.
/// Quick connect, new host and the sync state sit at the bottom.
final class SidebarRailView: NSView {
    struct Group: Equatable {
        var id: UUID?
        var name: String
        var hosts: [HostProfile]
    }

    static let width: CGFloat = 64

    var onConnect: ((HostProfile) -> Void)?
    var onNewHost: (() -> Void)?
    var onQuickConnect: (() -> Void)?
    var onSyncClick: (() -> Void)?

    private var theme: TerminalTheme
    private var groups: [Group] = []
    private var statuses: [UUID: SessionTabItem.State] = [:]
    private var selectedHostID: UUID?
    private var syncStatus: CloudSyncStatus = .disabled

    private let glass = GlassBackgroundView()
    private let border: ColorView
    private let scrollView = NSScrollView()
    private let groupColumn = FlippedView()
    private var groupItems: [RailItemView] = []
    private let quickConnectItem: RailItemView
    private let newHostItem: RailItemView
    private let syncItem: RailItemView

    /// The window buttons and, under them, the sidebar toggle take the top.
    private static let topInset: CGFloat = 70
    private static let itemSize: CGFloat = 44
    /// Group rows are taller than their 44 pt tile so the count badge, which
    /// sticks out above the tile's corner, is not clipped.
    private static let groupRowHeight: CGFloat = 52

    init(theme: TerminalTheme) {
        self.theme = theme
        border = ColorView(color: theme.sidebarDivider)
        quickConnectItem = RailItemView(symbol: "bolt.fill")
        newHostItem = RailItemView(symbol: "plus")
        syncItem = RailItemView(symbol: "icloud.slash")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(glass)
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.widthAnchor.constraint(equalToConstant: 1)
        ])

        scrollView.documentView = groupColumn
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        quickConnectItem.toolTip = "快速连接（⌘N）"
        quickConnectItem.onClick = { [weak self] _ in self?.onQuickConnect?() }
        newHostItem.toolTip = "新建主机（⇧⌘N）"
        newHostItem.onClick = { [weak self] _ in self?.onNewHost?() }
        syncItem.onClick = { [weak self] _ in self?.onSyncClick?() }
        for item in [quickConnectItem, newHostItem, syncItem] {
            addSubview(item)
        }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        applyTheme()
        rebuildGroups()
    }

    func update(groups: [Group], statuses: [UUID: SessionTabItem.State], selectedHostID: UUID?) {
        let changed = groups != self.groups
        self.groups = groups
        self.statuses = statuses
        self.selectedHostID = selectedHostID
        if changed {
            rebuildGroups()
        } else {
            refreshGroupState()
        }
    }

    func update(syncStatus: CloudSyncStatus) {
        self.syncStatus = syncStatus
        let (symbol, tint) = SyncStatusView.symbol(for: syncStatus, theme: theme)
        syncItem.symbol = symbol
        syncItem.tint = tint
        syncItem.toolTip = SyncStatusView.toolTip(for: syncStatus)
        syncItem.setAccessibilityLabel(syncStatus.title)
    }

    private func applyTheme() {
        glass.apply(
            theme: theme,
            material: .sidebar,
            topAlpha: theme.isDark ? 0.52 : 0.40,
            bottomAlpha: theme.isDark ? 0.68 : 0.50,
            accentGlow: true
        )
        border.color = theme.sidebarDivider
        for item in [quickConnectItem, newHostItem] {
            item.apply(theme: theme)
            item.tint = theme.tabText.withAlphaComponent(0.85)
        }
        syncItem.apply(theme: theme)
        update(syncStatus: syncStatus)
        needsDisplay = true
    }

    // MARK: - Groups

    private func rebuildGroups() {
        groupItems.forEach { $0.removeFromSuperview() }
        groupItems = groups.enumerated().map { index, group in
            let item = RailItemView(symbol: group.id == nil ? "tray.fill" : "folder.fill")
            item.apply(theme: theme)
            item.tint = theme.accent
            item.onClick = { [weak self] view in self?.showHosts(of: index, from: view) }
            groupColumn.addSubview(item)
            return item
        }
        refreshGroupState()
        needsLayout = true
    }

    private func refreshGroupState() {
        for (item, group) in zip(groupItems, groups) {
            let connected = group.hosts.filter { statuses[$0.id] == .connected }.count
            item.badge = connected
            item.isCurrent = group.hosts.contains { $0.id == selectedHostID }
            var tip = "\(group.name) · \(group.hosts.count) 台主机"
            if connected > 0 { tip += "，\(connected) 台已连接" }
            item.toolTip = tip
            item.setAccessibilityLabel(tip)
        }
    }

    private func showHosts(of index: Int, from item: RailItemView) {
        guard index < groups.count else { return }
        let group = groups[index]
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if group.hosts.isEmpty {
            let empty = NSMenuItem(title: "没有主机", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for host in group.hosts {
            let entry = NSMenuItem(title: host.displayName, action: #selector(hostChosen(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = host.id
            entry.toolTip = host.subtitle
            entry.image = Self.statusDot(statuses[host.id], idle: theme.subtle)
            entry.state = host.id == selectedHostID ? .on : .off
            menu.addItem(entry)
        }
        // Beside the icon, like a flyout, rather than under the pointer.
        menu.popUp(positioning: nil, at: NSPoint(x: item.bounds.maxX + 8, y: item.bounds.minY), in: item)
    }

    @objc private func hostChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let host = groups.lazy.flatMap(\.hosts).first(where: { $0.id == id }) else { return }
        onConnect?(host)
    }

    /// `idle` is the theme's muted colour: a dynamic system colour resolved
    /// inside the image's drawing came out black in a dark menu.
    private static func statusDot(_ state: SessionTabItem.State?, idle: NSColor) -> NSImage {
        let color: NSColor
        switch state {
        case .connected: color = NSColor(srgbRed: 0.29, green: 0.78, blue: 0.42, alpha: 1)
        case .connecting: color = NSColor(srgbRed: 0.95, green: 0.66, blue: 0.22, alpha: 1)
        case .failed: color = NSColor(srgbRed: 0.95, green: 0.35, blue: 0.35, alpha: 1)
        default: color = idle
        }
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Items span the rail so the "current" bar can sit on its edge; each
        // draws its highlight as a centred square.
        let size = Self.itemSize
        var bottom = bounds.height - 12
        for item in [syncItem, newHostItem, quickConnectItem] {
            bottom -= size
            item.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: size)
            bottom -= 2
        }
        let top = Self.topInset
        scrollView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bottom - 10 - top))
        let row = Self.groupRowHeight
        let contentHeight = CGFloat(groupItems.count) * row
        groupColumn.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(contentHeight, scrollView.frame.height))
        for (index, item) in groupItems.enumerated() {
            item.frame = NSRect(x: 0, y: CGFloat(index) * row, width: bounds.width, height: row)
        }
    }
}

/// One icon in the rail: hover highlight, a "current" bar and a count badge.
final class RailItemView: NSView {
    var onClick: ((RailItemView) -> Void)?
    var symbol: String { didSet { updateImage() } }
    var tint: NSColor = .labelColor { didSet { icon.contentTintColor = tint } }
    var badge = 0 { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }

    private let icon = NSImageView()
    private var theme: TerminalTheme = .midnight
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20)
        ])
        setAccessibilityRole(.button)
        updateImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        needsDisplay = true
    }

    private func updateImage() {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
    }

    /// The 44 pt square the icon and its highlight occupy.
    private var tile: NSRect {
        let side = min(bounds.height, 44)
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = tile.insetBy(dx: 1, dy: 1)
        if isCurrent || hovering {
            (isCurrent ? theme.selectedPillFill : theme.pillHoverFill).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        }
        if isCurrent {
            theme.accent.setFill()
            // A bar on the rail's outer edge, like the reference design.
            NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 4, y: bounds.midY - 14, width: 3, height: 28),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
        if badge > 0 {
            let text = badge > 9 ? "9+" : "\(badge)"
            let font = NSFont.systemFont(ofSize: 10, weight: .bold)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let width = max(16, textSize.width + 8)
            let badgeRect = NSRect(x: tile.maxX - width + 4, y: tile.minY - 3, width: width, height: 16)
            NSColor(srgbRed: 0.29, green: 0.74, blue: 0.42, alpha: 1).setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 8, yRadius: 8).fill()
            (text as NSString).draw(
                at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.white]
            )
        }
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(tile, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(self)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(self)
        return true
    }
}
