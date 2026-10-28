import AppKit

final class SessionOverlayView: NSView {
    enum Mode {
        case connecting(detail: String)
        case failed(title: String, detail: String)
        case disconnected(title: String, detail: String)
    }

    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onEdit: (() -> Void)?
    var onClose: (() -> Void)?

    private let card: RoundedCardView
    private let cardGlass = NSVisualEffectView()
    private let cardTint = ColorView(color: .clear)
    private let spinner = NSProgressIndicator()
    private let iconBadge: SymbolBadgeView
    private let titleLabel = UIFactory.label("", size: 16, weight: .semibold, color: .labelColor, alignment: .center)
    private let detailLabel = UIFactory.wrappingLabel("", size: 12.5, color: .secondaryLabelColor)
    /// The primary button is the accent only when it recovers the session
    /// (retry, reconnect); "取消" while connecting stays a quiet pill.
    private var primaryIsAccent = false
    private let primaryButton: ChromeButton
    private let secondaryButton: ChromeButton
    private let tertiaryButton: ChromeButton
    private let buttonStack = NSStackView()

    private var theme: TerminalTheme

    init(theme: TerminalTheme) {
        self.theme = theme
        card = RoundedCardView(fill: theme.tabActiveBackground, border: theme.border, radius: 14)
        iconBadge = SymbolBadgeView(
            symbol: "exclamationmark.triangle.fill",
            background: NSColor.systemOrange.withAlphaComponent(0.12),
            tint: .systemOrange,
            size: 40
        )
        primaryButton = ChromeButton(shape: .pill, title: "取消", target: nil, action: nil)
        secondaryButton = ChromeButton(shape: .pill, title: "关闭", target: nil, action: nil)
        tertiaryButton = ChromeButton(shape: .pill, title: "编辑主机", target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = theme.background.withAlphaComponent(0.82).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(card)

        // The card is frosted glass like the rest of the chrome: a behind-window
        // blur, then a thin theme tint. The card layer itself stays clear so its
        // fill never covers the blur; its border still draws on top.
        cardGlass.material = .popover
        cardGlass.blendingMode = .behindWindow
        cardGlass.state = .active
        cardGlass.wantsLayer = true
        cardGlass.layer?.cornerRadius = 14
        cardGlass.layer?.masksToBounds = true
        cardGlass.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardGlass)
        cardTint.layer?.cornerRadius = 14
        card.addSubview(cardTint)
        for layerView in [cardGlass, cardTint] {
            NSLayoutConstraint.activate([
                layerView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                layerView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                layerView.topAnchor.constraint(equalTo: card.topAnchor),
                layerView.bottomAnchor.constraint(equalTo: card.bottomAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -18),
            card.widthAnchor.constraint(equalToConstant: 380),
            card.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24)
        ])

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.controlSize = .small
        spinner.widthAnchor.constraint(equalToConstant: 20).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 20).isActive = true

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 6
        detailLabel.isSelectable = true
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.preferredMaxLayoutWidth = 330

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.addArrangedSubview(tertiaryButton)
        buttonStack.addArrangedSubview(secondaryButton)
        buttonStack.addArrangedSubview(primaryButton)

        primaryButton.target = self
        primaryButton.action = #selector(primaryPressed)
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryPressed)
        tertiaryButton.target = self
        tertiaryButton.action = #selector(tertiaryPressed)

        for button in [primaryButton, secondaryButton, tertiaryButton] {
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        primaryButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        secondaryButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        tertiaryButton.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let content = NSStackView(views: [spinner, iconBadge, titleLabel, detailLabel, buttonStack])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.setCustomSpacing(4, after: titleLabel)
        content.setCustomSpacing(18, after: detailLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        iconBadge.isHidden = true
        buttonStack.isHidden = true
        isHidden = true
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.background.withAlphaComponent(theme.isDark ? 0.28 : 0.12).cgColor
        card.fillColor = .clear
        // Tinted with the same background as the terminal glass, so the card
        // reads as a raised piece of that surface rather than a grey slab.
        cardTint.color = theme.isDark
            ? theme.background.withAlphaComponent(0.55)
            : NSColor.white.withAlphaComponent(0.62)
        card.borderColor = theme.pillBorder
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = theme.isDark ? 0.22 : 0.07
        card.layer?.shadowRadius = 18
        card.layer?.shadowOffset = CGSize(width: 0, height: -4)

        for button in [secondaryButton, tertiaryButton] {
            stylePill(button)
        }
        stylePrimary()
        titleLabel.textColor = theme.foreground
        detailLabel.textColor = theme.subtle
        needsLayout = true
    }

    private func stylePill(_ button: ChromeButton) {
        button.fillColor = theme.pillFill
        button.hoverFillColor = theme.pillHoverFill
        button.borderColor = theme.pillBorder
        button.titleColor = theme.tabText
    }

    private func stylePrimary() {
        guard primaryIsAccent else {
            stylePill(primaryButton)
            return
        }
        primaryButton.fillColor = theme.accent
        primaryButton.hoverFillColor = theme.accent.blended(withFraction: 0.12, of: .white) ?? theme.accent
        primaryButton.borderColor = .clear
        primaryButton.titleColor = .white
    }

    func showConnecting(detail: String, showCancel: Bool = true) {
        primaryIsAccent = false
        stylePrimary()
        isHidden = false
        spinner.isHidden = false
        spinner.startAnimation(nil)
        iconBadge.isHidden = true
        titleLabel.stringValue = "正在连接"
        titleLabel.textColor = theme.foreground
        detailLabel.stringValue = detail
        detailLabel.textColor = theme.subtle
        buttonStack.isHidden = !showCancel
        primaryButton.isHidden = false
        primaryButton.title = "取消"
        primaryButton.action = #selector(cancelPressed)
        secondaryButton.isHidden = true
        tertiaryButton.isHidden = true
    }

    func hideConnecting() {
        spinner.stopAnimation(nil)
        isHidden = true
    }

    func showFailure(title: String, detail: String, allowsEdit: Bool = true) {
        primaryIsAccent = true
        stylePrimary()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconBadge.isHidden = false
        let warning = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.25, alpha: 1)
        iconBadge.apply(
            background: warning.withAlphaComponent(0.12),
            tint: warning,
            symbol: "exclamationmark.triangle.fill",
            pointSize: 18
        )
        titleLabel.stringValue = title
        titleLabel.textColor = theme.foreground
        detailLabel.stringValue = detail
        detailLabel.textColor = theme.subtle
        buttonStack.isHidden = false
        primaryButton.isHidden = false
        primaryButton.title = "重试"
        primaryButton.action = #selector(retryPressed)
        secondaryButton.isHidden = false
        secondaryButton.title = "关闭"
        secondaryButton.action = #selector(closePressed)
        tertiaryButton.isHidden = !allowsEdit
        tertiaryButton.title = "编辑主机"
        isHidden = false
    }

    func showDisconnected(detail: String, title: String = "连接已断开", retryTitle: String = "重新连接") {
        primaryIsAccent = true
        stylePrimary()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconBadge.isHidden = false
        iconBadge.apply(
            background: theme.subtle.withAlphaComponent(0.12),
            tint: theme.subtle,
            symbol: "bolt.slash.fill",
            pointSize: 18
        )
        titleLabel.stringValue = title
        titleLabel.textColor = theme.foreground
        detailLabel.stringValue = detail
        detailLabel.textColor = theme.subtle
        buttonStack.isHidden = false
        primaryButton.isHidden = false
        primaryButton.title = retryTitle
        primaryButton.action = #selector(retryPressed)
        secondaryButton.isHidden = false
        secondaryButton.title = "关闭"
        secondaryButton.action = #selector(closePressed)
        tertiaryButton.isHidden = true
        isHidden = false
    }

    @objc private func primaryPressed() {
        if primaryButton.title == "取消" {
            cancelPressed()
        } else {
            retryPressed()
        }
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func retryPressed() {
        onRetry?()
    }

    @objc private func secondaryPressed() {
        onClose?()
    }

    @objc private func tertiaryPressed() {
        onEdit?()
    }

    @objc private func closePressed() {
        onClose?()
    }
}
