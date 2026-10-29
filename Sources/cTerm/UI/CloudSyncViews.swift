import AppKit

// MARK: - Settings section

/// The 云同步 block of the Settings window: setup when off, status and
/// actions when on.
final class CloudSyncSettingsView: NSView {
    weak var presenter: NSViewController?

    private var theme: TerminalTheme
    private let manager = CloudSyncManager.shared
    private let titleLabel: NSTextField
    private let statusLabel: NSTextField
    private let explainLabel: NSTextField
    private let setupHelp: NSTextField
    private let infoLabel: NSTextField
    private let errorLabel: NSTextField
    private let spinner = NSProgressIndicator()
    private let enableButton: NSButton
    private let syncButton: NSButton
    private let passwordButton: NSButton
    private let disableButton: NSButton
    private var setupViews: [NSView] = []
    private var enabledViews: [NSView] = []
    private var busy = false

    init(theme: TerminalTheme) {
        self.theme = theme
        titleLabel = UIFactory.label("云同步 · OneDrive", size: 13, weight: .semibold, color: theme.foreground)
        statusLabel = UIFactory.label("", size: 11, weight: .medium, color: theme.subtle, alignment: .right)
        explainLabel = UIFactory.wrappingLabel(
            "主机配置与已保存的密码、私钥口令会先在本机用同步密码加密（PBKDF2-SHA256 60 万轮 + AES-256-GCM），再上传到 OneDrive；云端只保存密文，cTerm 也只能访问 OneDrive 中它自己的应用文件夹。私钥文件也会一起同步，换电脑无需手动复制。忘记同步密码将无法恢复。",
            size: 11, color: theme.subtle
        )
        setupHelp = UIFactory.wrappingLabel("", size: 10, color: theme.subtle)
        infoLabel = UIFactory.wrappingLabel("", size: 11, color: theme.foreground)
        errorLabel = UIFactory.wrappingLabel("", size: 11, color: NSColor(srgbRed: 0.95, green: 0.42, blue: 0.42, alpha: 1))
        enableButton = UIFactory.button("登录 OneDrive…", target: nil, action: nil, color: theme.accent, textColor: .white)
        syncButton = UIFactory.button("立即同步", target: nil, action: nil)
        passwordButton = UIFactory.button("修改同步密码…", target: nil, action: nil)
        disableButton = UIFactory.button("关闭云同步", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        apply(theme: theme)
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .ctermSyncStatusDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func build() {
        for button in [enableButton, syncButton, passwordButton, disableButton] {
            button.controlSize = .regular
            button.target = self
        }
        enableButton.action = #selector(enablePressed)
        syncButton.action = #selector(syncPressed)
        passwordButton.action = #selector(passwordPressed)
        disableButton.action = #selector(disablePressed)

        let header = NSStackView(views: [titleLabel, NSView(), spinner, statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        setupHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let clientRow = NSStackView(views: [setupHelp, NSView(), enableButton])
        clientRow.orientation = .horizontal
        clientRow.alignment = .centerY
        clientRow.spacing = 12

        let actions = NSStackView(views: [syncButton, passwordButton, NSView(), disableButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        setupViews = [clientRow]
        enabledViews = [infoLabel, actions]

        let stack = NSStackView(views: [header, explainLabel, clientRow, infoLabel, actions, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(10, after: explainLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for view in [header, explainLabel, clientRow, infoLabel, actions, errorLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        titleLabel.textColor = theme.foreground
        statusLabel.textColor = theme.subtle
        explainLabel.textColor = theme.subtle
        setupHelp.textColor = theme.subtle
        infoLabel.textColor = theme.foreground
        enableButton.bezelColor = theme.accent
    }

    @objc func refresh() {
        let enabled = manager.isEnabled
        setupViews.forEach { $0.isHidden = enabled }
        enabledViews.forEach { $0.isHidden = !enabled }
        let status = manager.currentStatus
        statusLabel.stringValue = [status.title, status.detail].compactMap { $0 }.joined(separator: " · ")
        if busy || status == .syncing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        setupHelp.stringValue = manager.isAvailable
            ? "点击后会打开微软登录页面，授权 cTerm 读写 OneDrive 中它自己的应用文件夹。"
            : "此版本未内置 OneDrive 应用 ID，暂时无法开启云同步。"

        var lines: [String] = []
        if let account = manager.accountName { lines.append("帐户：\(account)") }
        if let path = manager.filePath { lines.append("文件：OneDrive / 应用 / cTerm / \(path)") }
        if let last = manager.lastSyncAt { lines.append("上次同步：\(CloudSyncStatus.relative(last))") }
        infoLabel.stringValue = lines.joined(separator: "\n")

        if case .failed(let message) = status {
            errorLabel.stringValue = message
            errorLabel.isHidden = false
        } else if errorLabel.stringValue.isEmpty || enabled {
            errorLabel.isHidden = true
        }
        let wrongPassword: Bool
        if case .failed(let message) = status,
           [SyncError.wrongPassword, .passwordMissing].contains(where: { $0.errorDescription == message }) {
            wrongPassword = true
        } else {
            wrongPassword = false
        }
        passwordButton.title = wrongPassword ? "重新输入同步密码…" : "修改同步密码…"
        syncButton.title = needsLogin ? "重新登录 OneDrive…" : "立即同步"
        for button in [enableButton, syncButton, passwordButton, disableButton] {
            button.isEnabled = !busy && status != .syncing
        }
        enableButton.isEnabled = enableButton.isEnabled && manager.isAvailable
    }

    private func showError(_ error: Error) {
        if case SyncError.cancelled = error { return }
        errorLabel.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorLabel.isHidden = false
    }

    private func setBusy(_ value: Bool) {
        busy = value
        if value {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }
        refresh()
    }

    // MARK: - Actions

    @objc private func enablePressed() {
        guard manager.isAvailable else { return }
        Task { await runEnableFlow() }
    }

    /// Sign in first (straight to Microsoft's page), then pick or create the
    /// file, then set the sync password (or enter the existing file's one).
    private func runEnableFlow() async {
        guard let presenter else { return }
        setBusy(true)
        defer { setBusy(false) }
        do {
            try await manager.signIn(from: window)
            guard let choice = await DriveFilePickerViewController.choose(theme: theme, from: presenter) else { return }
            var mode: SyncPasswordViewController.Mode
            switch choice {
            case .new: mode = .create
            case .existing(let item):
                mode = .reenter(reason: "请输入创建“\(item.name)”时设定的同步密码。")
            }
            while true {
                guard let password = await SyncPasswordViewController.prompt(mode: mode, theme: theme, from: presenter) else {
                    return
                }
                do {
                    switch choice {
                    case .existing(let item):
                        try await manager.enableWithExistingFile(item, password: password)
                    case .new(let name):
                        try await manager.enableWithNewFile(name: name, password: password)
                    }
                    break
                } catch SyncError.wrongPassword {
                    mode = .reenter(reason: "同步密码不正确，无法解密该文件。请输入创建该同步文件时设定的同步密码。")
                }
            }
        } catch {
            showError(error)
        }
    }

    private var needsLogin: Bool {
        if case .failed(let message) = manager.currentStatus {
            return message == SyncError.notSignedIn.errorDescription
        }
        return false
    }

    @objc private func syncPressed() {
        let relogin = needsLogin
        setBusy(true)
        Task {
            defer { setBusy(false) }
            do {
                if relogin { try await manager.signIn(from: window) }
                try await manager.sync()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func passwordPressed() {
        guard let presenter else { return }
        let reenter = passwordButton.title.hasPrefix("重新输入")
        Task {
            let mode: SyncPasswordViewController.Mode = reenter
                ? .reenter(reason: "请输入这个同步文件的同步密码。如果在其他设备上修改过同步密码，请输入新的密码。")
                : .change
            guard let password = await SyncPasswordViewController.prompt(mode: mode, theme: theme, from: presenter) else {
                return
            }
            setBusy(true)
            defer { setBusy(false) }
            do {
                if reenter {
                    if !manager.client.isSignedIn {
                        try await manager.signIn(from: window)
                    }
                    try await manager.updatePassword(password)
                } else {
                    try await manager.changePassword(to: password)
                }
            } catch {
                showError(error)
            }
        }
    }

    @objc private func disablePressed() {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "关闭云同步？"
        alert.informativeText = "本机的主机配置会保留；OneDrive 上的同步文件不会被删除。本机保存的同步密码和 OneDrive 授权会被移除。"
        alert.addButton(withTitle: "关闭同步")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.manager.disable()
            self?.refresh()
        }
    }
}

// MARK: - Sync password

final class SyncPasswordViewController: NSViewController {
    enum Mode {
        case create
        case change
        case reenter(reason: String)
    }

    var onFinish: ((String?) -> Void)?

    private let mode: Mode
    private let theme: TerminalTheme
    private let field = NSSecureTextField()
    private let confirmField = NSSecureTextField()
    private let strengthLabel: NSTextField
    private let errorLabel: NSTextField

    init(mode: Mode, theme: TerminalTheme) {
        self.mode = mode
        self.theme = theme
        strengthLabel = UIFactory.label("", size: 11, weight: .medium, color: theme.subtle)
        errorLabel = UIFactory.wrappingLabel("", size: 11, color: NSColor(srgbRed: 0.95, green: 0.42, blue: 0.42, alpha: 1))
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 450, height: needsConfirmation ? 340 : 270)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var needsConfirmation: Bool {
        if case .reenter = mode { return false }
        return true
    }

    /// Shows the sheet and returns the password, or nil when cancelled.
    @MainActor
    static func prompt(mode: Mode, theme: TerminalTheme, from presenter: NSViewController) async -> String? {
        await withCheckedContinuation { continuation in
            let controller = SyncPasswordViewController(mode: mode, theme: theme)
            controller.onFinish = { [weak presenter, weak controller] value in
                if let controller { presenter?.dismiss(controller) }
                continuation.resume(returning: value)
            }
            presenter.presentAsSheet(controller)
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        view = root
        GlassBackgroundView.installDialogBackdrop(in: root).applyDialog(theme: theme)

        let title: String
        let detail: String
        let action: String
        switch mode {
        case .create:
            title = "设定同步密码"
            detail = "同步密码用于在本机加密主机配置与凭据，只保存在本机，不会上传。其他设备加入同步时需要输入同一个密码。云端文件包含私钥，建议至少 12 位并混合多种字符。"
            action = "继续"
        case .change:
            title = "修改同步密码"
            detail = "云端文件会用新密码重新加密。其他设备下次同步时需要输入新密码。"
            action = "修改"
        case .reenter(let reason):
            title = "输入同步密码"
            detail = reason
            action = "确定"
        }

        let badge = SymbolBadgeView(symbol: "key.icloud.fill", background: theme.accent.withAlphaComponent(0.18),
                                    tint: theme.accent, size: 38)
        let titleLabel = UIFactory.label(title, size: 18, weight: .semibold, color: theme.foreground)
        let detailLabel = UIFactory.wrappingLabel(detail, size: 11, color: theme.subtle)

        for (input, placeholder) in [(field, "同步密码"), (confirmField, "再次输入同步密码")] {
            input.placeholderString = placeholder
            input.font = .systemFont(ofSize: 13)
            input.bezelStyle = .roundedBezel
            input.translatesAutoresizingMaskIntoConstraints = false
            input.heightAnchor.constraint(equalToConstant: 28).isActive = true
            input.target = self
            input.action = #selector(submitPressed)
        }
        field.delegate = self
        confirmField.isHidden = !needsConfirmation
        strengthLabel.isHidden = !needsConfirmation
        errorLabel.isHidden = true

        let cancel = UIFactory.button("取消", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let submit = UIFactory.button(action, target: self, action: #selector(submitPressed),
                                      color: theme.accent, textColor: .white)
        submit.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, submit])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [badge, titleLabel, detailLabel, field, confirmField, strengthLabel, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: badge)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(16, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 38),
            badge.heightAnchor.constraint(equalToConstant: 38),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            confirmField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 12)
        ])
        updateStrength()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeGlassBacked()
        view.window?.makeFirstResponder(field)
    }

    static func strength(of password: String) -> (score: Int, title: String) {
        var classes = 0
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }
        let length = password.count
        if length < CloudSyncManager.minimumPasswordLength { return (0, "太短（至少 \(CloudSyncManager.minimumPasswordLength) 位）") }
        if length >= 16 || (length >= 12 && classes >= 3) { return (3, "强") }
        if length >= 12 || classes >= 3 { return (2, "中等") }
        return (1, "弱：建议加长或混合大小写、数字、符号")
    }

    private func updateStrength() {
        let value = field.stringValue
        guard !value.isEmpty else {
            strengthLabel.stringValue = "密码强度：—"
            strengthLabel.textColor = theme.subtle
            return
        }
        let result = Self.strength(of: value)
        strengthLabel.stringValue = "密码强度：\(result.title)"
        strengthLabel.textColor = [theme.ansiColor(1), theme.ansiColor(3), theme.ansiColor(3), theme.ansiColor(2)][result.score]
    }

    @objc private func submitPressed() {
        let value = field.stringValue
        if value.isEmpty {
            return fail("请输入同步密码。")
        }
        if needsConfirmation {
            if Self.strength(of: value).score == 0 {
                return fail("同步密码至少需要 \(CloudSyncManager.minimumPasswordLength) 位。")
            }
            if value != confirmField.stringValue {
                return fail("两次输入的密码不一致。")
            }
        }
        onFinish?(value)
        onFinish = nil
    }

    private func fail(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        NSSound.beep()
    }

    @objc private func cancelPressed() {
        onFinish?(nil)
        onFinish = nil
    }
}

extension SyncPasswordViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateStrength()
        errorLabel.isHidden = true
    }
}

// MARK: - OneDrive file picker

/// Picks the sync file: one cTerm created earlier (on this or another Mac
/// signed in to the same Microsoft account), or a new one. With the app-folder
/// scope cTerm sees only its own folder, so this is a flat list, not a browser.
final class DriveFilePickerViewController: NSViewController {
    enum Choice {
        case existing(DriveItem)
        case new(name: String)
    }

    typealias Loader = () async throws -> [DriveItem]

    var onFinish: ((Choice?) -> Void)?

    private let theme: TerminalTheme
    private let loader: Loader
    private var items: [DriveItem] = []
    private var loadTask: Task<Void, Never>?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let spinner = NSProgressIndicator()
    private let messageLabel: NSTextField
    private let nameField = NSTextField()
    private let createButton: NSButton
    private let chooseButton: NSButton

    init(theme: TerminalTheme, loader: @escaping Loader) {
        self.theme = theme
        self.loader = loader
        messageLabel = UIFactory.wrappingLabel("", size: 11, color: theme.subtle)
        createButton = UIFactory.button("新建", target: nil, action: nil)
        chooseButton = UIFactory.button("使用所选文件", target: nil, action: nil, color: theme.accent, textColor: .white)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 540, height: 460)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    static func choose(theme: TerminalTheme, from presenter: NSViewController) async -> Choice? {
        let client = CloudSyncManager.shared.client
        return await withCheckedContinuation { continuation in
            let controller = DriveFilePickerViewController(theme: theme) {
                try await client.listFiles()
            }
            controller.onFinish = { [weak presenter, weak controller] choice in
                if let controller { presenter?.dismiss(controller) }
                continuation.resume(returning: choice)
            }
            presenter.presentAsSheet(controller)
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        view = root
        GlassBackgroundView.installDialogBackdrop(in: root).applyDialog(theme: theme)

        let titleLabel = UIFactory.label("选择同步文件", size: 18, weight: .semibold, color: theme.foreground)
        let detail = UIFactory.wrappingLabel(
            "列表中是 OneDrive「应用 / cTerm」文件夹里的同步文件（包括其他 Mac 创建的）。第一次使用请新建一个；cTerm 看不到 OneDrive 里的其他文件。",
            size: 11, color: theme.subtle
        )
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let listLabel = UIFactory.label("已有同步文件", size: 12, weight: .medium, color: theme.subtle)
        let listHeader = NSStackView(views: [listLabel, NSView(), spinner])
        listHeader.orientation = .horizontal
        listHeader.alignment = .centerY

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 34
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(choosePressed)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let card = RoundedCardView(fill: theme.pillFill, border: theme.pillBorder, radius: 10)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scrollView)
        card.addSubview(messageLabel)
        messageLabel.alignment = .center

        nameField.stringValue = CloudSyncManager.defaultFileName
        nameField.placeholderString = "新文件名"
        nameField.font = .systemFont(ofSize: 12)
        nameField.bezelStyle = .roundedBezel
        nameField.translatesAutoresizingMaskIntoConstraints = false
        createButton.controlSize = .regular
        createButton.target = self
        createButton.action = #selector(createPressed)
        let newLabel = UIFactory.label("新建文件", size: 12, weight: .medium, color: theme.subtle)
        let createRow = NSStackView(views: [newLabel, nameField, createButton])
        createRow.orientation = .horizontal
        createRow.alignment = .centerY
        createRow.spacing = 8

        let cancel = UIFactory.button("取消", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        chooseButton.target = self
        chooseButton.action = #selector(choosePressed)
        chooseButton.keyEquivalent = "\r"
        chooseButton.isEnabled = false
        let buttons = NSStackView(views: [NSView(), cancel, chooseButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [titleLabel, detail, listHeader, card, createRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(14, after: detail)
        stack.setCustomSpacing(14, after: createRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            createRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            messageLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24)
        ])
        load()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeGlassBacked()
    }

    private func load() {
        messageLabel.isHidden = true
        spinner.startAnimation(nil)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.loader()
                guard !Task.isCancelled else { return }
                self.items = result
                self.messageLabel.stringValue = "还没有同步文件，请在下方新建一个。"
                self.messageLabel.isHidden = !result.isEmpty
            } catch {
                guard !Task.isCancelled else { return }
                self.messageLabel.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.messageLabel.isHidden = false
            }
            self.spinner.stopAnimation(nil)
            self.tableView.reloadData()
            self.updateButtons()
        }
    }

    private var selectedItem: DriveItem? {
        let row = tableView.selectedRow
        return row >= 0 && row < items.count ? items[row] : nil
    }

    private func updateButtons() {
        chooseButton.isEnabled = selectedItem != nil
    }

    @objc private func choosePressed() {
        guard let item = selectedItem else { return }
        finish(.existing(item))
    }

    @objc private func createPressed() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            return
        }
        finish(.new(name: name))
    }

    @objc private func cancelPressed() {
        finish(nil)
    }

    private func finish(_ choice: Choice?) {
        loadTask?.cancel()
        onFinish?(choice)
        onFinish = nil
    }
}

extension DriveFilePickerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = DriveItemCellView()
        cell.configure(item: items[row], theme: theme)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}

private final class DriveItemCellView: NSTableCellView {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    /// Graph usually sends whole seconds ("2026-10-26T09:12:00Z").
    private static let plainFormatter = ISO8601DateFormatter()

    private let icon = NSImageView()
    private let nameLabel = UIFactory.label("", size: 12, weight: .medium, color: .labelColor)
    private let detailLabel = UIFactory.label("", size: 10, weight: .regular, color: .secondaryLabelColor, alignment: .right)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(nameLabel)
        addSubview(detailLabel)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(item: DriveItem, theme: TerminalTheme) {
        icon.image = NSImage(systemSymbolName: "lock.doc.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        icon.contentTintColor = theme.accent
        nameLabel.stringValue = item.name
        nameLabel.textColor = theme.foreground
        var parts = [ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)]
        if let text = item.lastModifiedDateTime, let date = Self.isoFormatter.date(from: text) ?? Self.plainFormatter.date(from: text) {
            parts.insert(CloudSyncStatus.relative(date), at: 0)
        }
        detailLabel.stringValue = parts.joined(separator: " · ")
        detailLabel.textColor = theme.subtle
    }
}
