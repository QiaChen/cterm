import AppKit

final class SecretPromptViewController: NSViewController {
    struct Configuration {
        let title: String
        let message: String
        let detail: String
        let fieldPlaceholder: String
        let actionTitle: String
        let allowsRemembering: Bool
        let rememberByDefault: Bool
        let rememberTitle: String
    }

    var onSubmit: ((String, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let configuration: Configuration
    private let theme: TerminalTheme
    private let field = NSSecureTextField()
    private let rememberCheckbox = ThemedCheckbox(title: "记住")
    private let errorLabel: NSTextField
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField

    init(configuration: Configuration, theme: TerminalTheme) {
        self.configuration = configuration
        self.theme = theme
        titleLabel = UIFactory.label(configuration.title, size: 18, weight: .semibold, color: theme.foreground)
        detailLabel = UIFactory.wrappingLabel(configuration.detail, size: 11, color: theme.subtle)
        errorLabel = UIFactory.wrappingLabel("", size: 11, color: NSColor(srgbRed: 0.95, green: 0.42, blue: 0.42, alpha: 1))
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 430, height: 270)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        // Sheets don't reliably inherit the main window's appearance, so system
        // controls (checkbox titles, popups) would follow the OS theme instead.
        root.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        view = root
        GlassBackgroundView.installDialogBackdrop(in: root).applyDialog(theme: theme)

        let badge = SymbolBadgeView(
            symbol: "lock.shield.fill",
            background: theme.accent.withAlphaComponent(0.18),
            tint: theme.accent,
            size: 38
        )
        let header = NSStackView(views: [badge, NSView()])
        header.orientation = .horizontal
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        let titleStack = NSStackView(views: [titleLabel, detailLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleStack)

        field.placeholderString = configuration.fieldPlaceholder
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(submitPressed)
        root.addSubview(field)

        rememberCheckbox.font = .systemFont(ofSize: 12)
        rememberCheckbox.contentTintColor = theme.foreground
        rememberCheckbox.titleColor = theme.foreground
        rememberCheckbox.title = configuration.rememberTitle
        rememberCheckbox.state = configuration.rememberByDefault ? .on : .off
        rememberCheckbox.isHidden = !configuration.allowsRemembering
        rememberCheckbox.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rememberCheckbox)

        errorLabel.isHidden = true
        root.addSubview(errorLabel)

        let cancel = UIFactory.button("取消", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let submit = UIFactory.button(configuration.actionTitle, target: self, action: #selector(submitPressed),
                                      color: theme.accent, textColor: .white)
        submit.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, submit])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),

            titleStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            titleStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            titleStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),

            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            field.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 16),
            field.heightAnchor.constraint(equalToConstant: 28),

            rememberCheckbox.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            rememberCheckbox.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            rememberCheckbox.heightAnchor.constraint(equalToConstant: 20),

            errorLabel.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: rememberCheckbox.bottomAnchor, constant: 8),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: errorLabel.bottomAnchor, constant: 12)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeGlassBacked()
        view.window?.makeFirstResponder(field)
    }

    @objc private func submitPressed() {
        let value = field.stringValue
        guard !value.isEmpty else {
            errorLabel.stringValue = "请输入内容。"
            errorLabel.isHidden = false
            NSSound.beep()
            return
        }
        onSubmit?(value, rememberCheckbox.state == .on && !rememberCheckbox.isHidden)
    }

    @objc private func cancelPressed() {
        onCancel?()
    }
}
