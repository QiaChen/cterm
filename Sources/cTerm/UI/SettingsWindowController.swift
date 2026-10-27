import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let settingsVC = SettingsViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 624),
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

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private final class SettingsViewController: NSViewController {
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
        subtitleLabel = UIFactory.label("外观、云同步与本地数据", size: 12, weight: .regular, color: theme.subtle)
        fontValueLabel = UIFactory.label("13 pt", size: 12, weight: .medium, color: theme.foreground)
        preview = ThemePreviewView(theme: theme, fontSize: AppearancePreferences.fontSize)
        dataLabel = UIFactory.label("本地数据", size: 13, weight: .semibold, color: theme.foreground)
        pathLabel = UIFactory.label(AppPaths.supportDirectory.path, size: 10, weight: .regular, color: theme.subtle)
        syncSection = CloudSyncSettingsView(theme: theme)
        dividers = [HairlineView(color: theme.border), HairlineView(color: theme.border)]
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 540, height: 624)
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
        let masterButton = UIFactory.button("修改主密码…", target: self, action: #selector(changeMasterPassword))
        masterButton.controlSize = .regular
        let storageRow = NSStackView(views: [dataLabel, NSView(), masterButton, storageButton])
        storageRow.spacing = 8
        storageRow.orientation = .horizontal
        storageRow.alignment = .centerY
        storageRow.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = AppPaths.supportDirectory.path

        let security = UIFactory.wrappingLabel(
            "记住的密码、私钥口令和私钥副本保存在配置文件夹的 credentials.json 中，用主密码加密（PBKDF2-SHA256 + AES-256-GCM）。主机密钥采用首次使用信任（TOFU）并记录在本地 known_hosts.json。",
            size: 11,
            color: theme.subtle
        )
        let version = UIFactory.label("cTerm 1.0.0 · 原生 Swift SSH", size: 10, weight: .regular,
                                      color: theme.subtle.withAlphaComponent(0.65))

        let stack = NSStackView(views: [
            followRow, themeRow, fontRow, preview, dividers[0], syncSection, dividers[1],
            storageRow, pathLabel, security, version
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            titleStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),

            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),

            followRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            themeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fontRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dividers[0].widthAnchor.constraint(equalTo: stack.widthAnchor),
            dividers[1].widthAnchor.constraint(equalTo: stack.widthAnchor),
            syncSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            storageRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            security.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        fontValueLabel.stringValue = "\(Int(AppearancePreferences.fontSize)) pt"
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

    @objc private func changeMasterPassword() {
        let controller = MasterPasswordViewController(mode: .change, theme: theme)
        controller.onDone = { [weak self, weak controller] in
            guard let controller else { return }
            self?.dismiss(controller)
        }
        controller.onCancel = { [weak self, weak controller] in
            guard let controller else { return }
            self?.dismiss(controller)
        }
        presentAsSheet(controller)
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
        dividers.forEach { $0.color = theme.border }
        view.needsDisplay = true
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
