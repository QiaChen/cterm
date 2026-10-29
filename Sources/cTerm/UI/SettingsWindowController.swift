import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let settingsVC = SettingsViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 572),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.makeGlassBacked()
        window.appearance = NSAppearance(named: AppearancePreferences.theme.isDark ? .darkAqua : .aqua)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = settingsVC
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showTab(_ tab: SettingsTab) {
        settingsVC.select(tab)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

enum SettingsTab: Int, CaseIterable {
    case general, sync, ai

    var title: String {
        switch self {
        case .general: return "基本设置"
        case .sync: return "云同步"
        case .ai: return "AI"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .sync: return "icloud"
        case .ai: return "sparkles"
        }
    }
}

private final class SettingsViewController: NSViewController {
    private static let lastTabKey = "cterm.settingsTab"
    private let tabBar = SettingsTabBar()
    private var pages: [SettingsTab: NSView] = [:]
    private let aiSection: AISettingsView
    private var theme = AppearancePreferences.theme
    private var glass: GlassBackgroundView?
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let themePopup = HandPopUpButton()
    private let followCheckbox = ThemedCheckbox(title: "跟随系统外观")
    private let fontSlider = HandSlider()
    private let fontValueLabel: NSTextField
    private let preview: ThemePreviewView
    private let dataLabel: NSTextField
    private let pathLabel: NSTextField
    private let syncSection: CloudSyncSettingsView
    private let dividers: [HairlineView]

    init() {
        titleLabel = UIFactory.label("设置", size: 22, weight: .bold, color: theme.foreground)
        subtitleLabel = UIFactory.label("外观、云同步、AI 与本地数据", size: 12, weight: .regular, color: theme.subtle)
        fontValueLabel = UIFactory.label("13 pt", size: 12, weight: .medium, color: theme.foreground)
        preview = ThemePreviewView(theme: theme, fontSize: AppearancePreferences.fontSize)
        dataLabel = UIFactory.label("本地数据", size: 13, weight: .semibold, color: theme.foreground)
        pathLabel = UIFactory.label(AppPaths.supportDirectory.path, size: 10, weight: .regular, color: theme.subtle)
        syncSection = CloudSyncSettingsView(theme: theme)
        aiSection = AISettingsView(theme: theme)
        dividers = [HairlineView(color: theme.border)]
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 540, height: 572)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .ctermThemeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontChanged),
            name: .ctermFontSizeDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root
        glass = GlassBackgroundView.installDialogBackdrop(in: root)
        glass?.applyDialog(theme: theme)

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleStack)

        let themeLabel = UIFactory.label("主题", size: 12, weight: .medium, color: theme.subtle)
        themeLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        themePopup.addItems(withTitles: TerminalTheme.all.map(\.name))
        themePopup.selectItem(at: TerminalTheme.all.firstIndex(where: { $0.id == theme.id }) ?? 0)
        followCheckbox.font = .systemFont(ofSize: 12)
        followCheckbox.titleColor = theme.foreground
        followCheckbox.state = AppearancePreferences.followsSystemAppearance ? .on : .off
        followCheckbox.target = self
        followCheckbox.action = #selector(followSystemToggled)
        followCheckbox.translatesAutoresizingMaskIntoConstraints = false
        let followRow = NSStackView(views: [followCheckbox, NSView()])
        followRow.orientation = .horizontal
        followRow.alignment = .centerY
        followRow.translatesAutoresizingMaskIntoConstraints = false
        themePopup.target = self
        themePopup.action = #selector(themeSelected)
        themePopup.translatesAutoresizingMaskIntoConstraints = false
        let themeRow = NSStackView(views: [themeLabel, themePopup, NSView()])
        themeRow.orientation = .horizontal
        themeRow.alignment = .centerY
        themeRow.spacing = 10
        themeRow.translatesAutoresizingMaskIntoConstraints = false

        let fontLabel = UIFactory.label("字体大小", size: 12, weight: .medium, color: theme.subtle)
        fontLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        fontSlider.minValue = 10
        fontSlider.maxValue = 24
        fontSlider.doubleValue = Double(AppearancePreferences.fontSize)
        fontSlider.isContinuous = true
        fontSlider.target = self
        fontSlider.action = #selector(fontSizeChanged)
        fontSlider.translatesAutoresizingMaskIntoConstraints = false
        fontSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        fontValueLabel.alignment = .right
        fontValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        fontValueLabel.translatesAutoresizingMaskIntoConstraints = false
        let fontRow = NSStackView(views: [fontLabel, fontSlider, fontValueLabel, NSView()])
        fontRow.orientation = .horizontal
        fontRow.alignment = .centerY
        fontRow.spacing = 10
        fontRow.translatesAutoresizingMaskIntoConstraints = false

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 108).isActive = true

        syncSection.presenter = self
        let storageButton = UIFactory.button("打开配置文件夹", target: self, action: #selector(openSupportFolder))
        storageButton.controlSize = .regular
        let storageRow = NSStackView(views: [dataLabel, NSView(), storageButton])
        storageRow.spacing = 8
        storageRow.orientation = .horizontal
        storageRow.alignment = .centerY
        storageRow.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = AppPaths.supportDirectory.path

        let security = UIFactory.wrappingLabel(
            "记住的密码、私钥口令和私钥副本保存在配置文件夹的 credentials.json 中，用 AES-256-GCM 加密，密钥保存在 macOS 钥匙串中。主机密钥采用首次使用信任（TOFU）并记录在本地 known_hosts.json。",
            size: 11,
            color: theme.subtle
        )
        let version = UIFactory.label("cTerm 1.0.0 · https://cterm.cqq.me", size: 10, weight: .regular,
                                      color: theme.subtle.withAlphaComponent(0.65))

        let stack = NSStackView(views: [
            followRow, themeRow, fontRow, preview, dividers[0], storageRow, pathLabel, security, version
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: preview)
        stack.setCustomSpacing(18, after: dividers[0])
        stack.translatesAutoresizingMaskIntoConstraints = false

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] tab in self?.select(tab) }
        root.addSubview(tabBar)
        pages = [.general: stack, .sync: syncSection, .ai: aiSection]

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            titleStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            tabBar.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 16),
            tabBar.heightAnchor.constraint(equalToConstant: 30),

            followRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            themeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fontRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dividers[0].widthAnchor.constraint(equalTo: stack.widthAnchor),
            storageRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            security.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for page in pages.values {
            page.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
                page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
                page.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 22),
                page.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
            ])
        }
        tabBar.apply(theme: theme)
        let saved = SettingsTab(rawValue: UserDefaults.standard.integer(forKey: Self.lastTabKey)) ?? .general
        select(saved)

        fontValueLabel.stringValue = "\(Int(AppearancePreferences.fontSize)) pt"
    }

    func select(_ tab: SettingsTab) {
        loadViewIfNeeded()
        tabBar.selected = tab
        for (key, page) in pages { page.isHidden = key != tab }
        UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey)
    }

    @objc private func themeSelected() {
        let index = themePopup.indexOfSelectedItem
        guard index >= 0, index < TerminalTheme.all.count else { return }
        AppearancePreferences.theme = TerminalTheme.all[index]
        followCheckbox.state = .off
    }

    @objc private func followSystemToggled() {
        AppearancePreferences.followsSystemAppearance = followCheckbox.state == .on
        updateThemeControls()
    }

    @objc private func fontSizeChanged() {
        let value = CGFloat(Int(fontSlider.doubleValue.rounded()))
        fontValueLabel.stringValue = "\(Int(value)) pt"
        AppearancePreferences.fontSize = value
    }

    @objc private func openSupportFolder() {
        NSWorkspace.shared.open(AppPaths.supportDirectory)
    }

    @objc private func themeChanged() {
        theme = AppearancePreferences.theme
        updateThemeControls()
        applyTheme()
    }

    private func updateThemeControls() {
        followCheckbox.state = AppearancePreferences.followsSystemAppearance ? .on : .off
        if let index = TerminalTheme.all.firstIndex(where: { $0.id == theme.id }) {
            themePopup.selectItem(at: index)
        }
    }

    @objc private func fontChanged() {
        fontSlider.doubleValue = Double(AppearancePreferences.fontSize)
        fontValueLabel.stringValue = "\(Int(AppearancePreferences.fontSize)) pt"
        preview.fontSize = AppearancePreferences.fontSize
    }

    private func applyTheme() {
        glass?.applyDialog(theme: theme)
        view.window?.makeGlassBacked()
        view.window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        titleLabel.textColor = theme.foreground
        subtitleLabel.textColor = theme.subtle
        followCheckbox.titleColor = theme.foreground
        dataLabel.textColor = theme.foreground
        pathLabel.textColor = theme.subtle
        preview.theme = theme
        syncSection.apply(theme: theme)
        aiSection.apply(theme: theme)
        tabBar.apply(theme: theme)
        dividers.forEach { $0.color = theme.border }
        view.needsDisplay = true
    }
}

/// Pill tabs at the top of Settings, styled like the session tabs.
private final class SettingsTabBar: NSView {
    var onSelect: ((SettingsTab) -> Void)?
    var selected: SettingsTab = .general {
        didSet { buttons.forEach { $0.isSelected = $0.tab == selected } }
    }

    private var buttons: [SettingsTabButton] = []

    init() {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for tab in SettingsTab.allCases {
            let button = SettingsTabButton(tab: tab)
            button.target = self
            button.action = #selector(tapped(_:))
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: TerminalTheme) {
        buttons.forEach { $0.apply(theme: theme) }
    }

    @objc private func tapped(_ sender: SettingsTabButton) {
        onSelect?(sender.tab)
    }
}

private final class SettingsTabButton: NSButton {
    let tab: SettingsTab
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    private var theme = AppearancePreferences.theme
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(tab: SettingsTab) {
        self.tab = tab
        super.init(frame: .zero)
        title = tab.title
        isBordered = false
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityLabel(tab.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        needsDisplay = true
    }

    private var titleFont: NSFont { .systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .medium) }

    override var intrinsicContentSize: NSSize {
        let width = (tab.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width
        return NSSize(width: ceil(width) + 16 + 6 + 24, height: 30)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

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

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        if isSelected {
            theme.selectedPillFill.setFill()
            path.fill()
            theme.selectedPillBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            theme.pillHoverFill.setFill()
            path.fill()
        }
        let color = isSelected || hovering ? theme.tabText : theme.tabInactiveText
        let title = tab.title as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: color]
        let size = title.size(withAttributes: attributes)
        let symbol = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium).applying(.init(paletteColors: [color])))
        let iconWidth = symbol?.size.width ?? 0
        var x = (bounds.width - iconWidth - 6 - size.width) / 2
        if let symbol {
            symbol.draw(in: NSRect(x: x, y: (bounds.height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            x += iconWidth + 6
        }
        title.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

final class ThemePreviewView: NSView {
    var theme: TerminalTheme {
        didSet { needsDisplay = true }
    }
    var fontSize: CGFloat {
        didSet { needsDisplay = true }
    }

    init(theme: TerminalTheme, fontSize: CGFloat) {
        self.theme = theme
        self.fontSize = fontSize
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 10
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        theme.background.setFill()
        path.fill()
        theme.border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        var y = bounds.height - 26
        let lineHeight: CGFloat = 22
        draw(segments: [
            ("cole@studio", theme.ansiColor(2)),
            (" ~ % ", theme.foreground),
            ("git status", theme.foreground)
        ], x: 16, y: y, font: font)
        y -= lineHeight
        draw(segments: [("On branch main", theme.subtle)], x: 16, y: y, font: font)
        y -= lineHeight
        draw(segments: [("\u{2714} working tree clean", theme.ansiColor(2))], x: 16, y: y, font: font)
        y -= lineHeight
        draw(segments: [("\u{276F} ", theme.accent), ("swift build", theme.foreground)], x: 16, y: y, font: font)
    }

    private func draw(segments: [(String, NSColor)], x: CGFloat, y: CGFloat, font: NSFont) {
        let line = NSMutableAttributedString()
        for (text, color) in segments {
            line.append(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color]
            ))
        }
        line.draw(at: NSPoint(x: x, y: y))
    }

}
