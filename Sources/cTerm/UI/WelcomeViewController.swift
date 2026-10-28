import AppKit

final class WelcomeViewController: NSViewController {
    var onNewHost: (() -> Void)?
    var onQuickConnect: (() -> Void)?
    var onLocalTerminal: (() -> Void)?

    private var theme: TerminalTheme
    private let iconBadge: SymbolBadgeView
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let newHostButton: ChromeButton
    private let quickConnectButton: ChromeButton
    private let localTerminalButton: ChromeButton
    private let featureStack = NSStackView()
    private let hintLabel: NSTextField

    init(theme: TerminalTheme) {
        self.theme = theme
        iconBadge = SymbolBadgeView(
            symbol: "terminal.fill",
            background: theme.accent.withAlphaComponent(0.18),
            tint: theme.accent,
            size: 78
        )
        titleLabel = UIFactory.label("cTerm", size: 34, weight: .bold, color: theme.foreground, alignment: .center)
        subtitleLabel = UIFactory.label("原生、安全的 SSH 工作台", size: 15, weight: .regular,
                                        color: theme.subtle, alignment: .center)
        newHostButton = ChromeButton(shape: .pill, title: "新建主机", symbol: "plus", target: nil, action: nil)
        quickConnectButton = ChromeButton(shape: .pill, title: "快速连接", symbol: "bolt.fill", target: nil, action: nil)
        localTerminalButton = ChromeButton(shape: .pill, title: "本地终端", symbol: "apple.terminal", target: nil, action: nil)
        hintLabel = UIFactory.label("双击主机即可在新标签页中连接", size: 12, weight: .regular,
                                    color: theme.subtle.withAlphaComponent(0.8), alignment: .center)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private let divider = HairlineView(color: .clear)

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false

        divider.color = theme.sidebarDivider
        divider.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        stack.addArrangedSubview(iconBadge)
        stack.setCustomSpacing(20, after: iconBadge)
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(6, after: titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(26, after: subtitleLabel)

        newHostButton.target = self
        newHostButton.action = #selector(newHostPressed)
        newHostButton.widthAnchor.constraint(equalToConstant: 124).isActive = true
        newHostButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        quickConnectButton.target = self
        quickConnectButton.action = #selector(quickConnectPressed)
        quickConnectButton.widthAnchor.constraint(equalToConstant: 136).isActive = true
        quickConnectButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        localTerminalButton.target = self
        localTerminalButton.action = #selector(localTerminalPressed)
        localTerminalButton.toolTip = "在本机打开一个终端（⌥⌘T）"
        localTerminalButton.widthAnchor.constraint(equalToConstant: 136).isActive = true
        localTerminalButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let buttons = NSStackView(views: [newHostButton, quickConnectButton, localTerminalButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        stack.addArrangedSubview(buttons)
        stack.setCustomSpacing(30, after: buttons)
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(22, after: divider)

        featureStack.orientation = .horizontal
        featureStack.spacing = 22
        featureStack.alignment = .centerY
        stack.addArrangedSubview(featureStack)
        stack.setCustomSpacing(20, after: featureStack)
        stack.addArrangedSubview(hintLabel)

        iconBadge.heightAnchor.constraint(equalToConstant: 78).isActive = true
        iconBadge.widthAnchor.constraint(equalToConstant: 78).isActive = true
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        subtitleLabel.font = .systemFont(ofSize: 15)
        hintLabel.font = .systemFont(ofSize: 12)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40)
        ])

        rebuildFeatures()
        apply(theme: theme)
    }

    private func rebuildFeatures() {
        for view in featureStack.arrangedSubviews {
            featureStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let features: [(String, String)] = [
            ("square.stack.3d.up.fill", "多标签会话"),
            ("folder.fill", "SFTP 文件管理"),
            ("checkmark.shield.fill", "主机指纹校验"),
            ("lock.icloud.fill", "加密云同步")
        ]
        for (symbol, text) in features {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.contentTintColor = theme.subtle.withAlphaComponent(0.85)
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 13).isActive = true
            image.heightAnchor.constraint(equalToConstant: 13).isActive = true
            let label = UIFactory.label(text, size: 12, weight: .medium, color: theme.subtle.withAlphaComponent(0.9))
            let row = NSStackView(views: [image, label])
            row.orientation = .horizontal
            row.spacing = 5
            row.alignment = .centerY
            featureStack.addArrangedSubview(row)
        }
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        view.layer?.backgroundColor = NSColor.clear.cgColor
        titleLabel.textColor = theme.tabText
        subtitleLabel.textColor = theme.subtle
        hintLabel.textColor = theme.subtle.withAlphaComponent(0.75)
        newHostButton.fillColor = theme.accent
        newHostButton.hoverFillColor = theme.accent.blended(withFraction: 0.15, of: .white) ?? theme.accent
        newHostButton.borderColor = .clear
        newHostButton.titleColor = .white
        newHostButton.needsDisplay = true
        quickConnectButton.fillColor = theme.pillFill
        quickConnectButton.hoverFillColor = theme.pillHoverFill
        quickConnectButton.borderColor = theme.pillBorder
        quickConnectButton.titleColor = theme.tabText
        quickConnectButton.needsDisplay = true
        localTerminalButton.fillColor = theme.pillFill
        localTerminalButton.hoverFillColor = theme.pillHoverFill
        localTerminalButton.borderColor = theme.pillBorder
        localTerminalButton.titleColor = theme.tabText
        localTerminalButton.needsDisplay = true
        iconBadge.layer?.backgroundColor = theme.accent.withAlphaComponent(0.18).cgColor
        divider.color = theme.sidebarDivider
        subtitleLabel.needsDisplay = true
        rebuildFeatures()
    }

    @objc private func newHostPressed() {
        onNewHost?()
    }

    @objc private func quickConnectPressed() {
        onQuickConnect?()
    }

    @objc private func localTerminalPressed() {
        onLocalTerminal?()
    }
}
