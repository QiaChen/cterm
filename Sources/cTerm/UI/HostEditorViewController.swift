import AppKit

final class HostEditorViewController: NSViewController {
    enum Mode {
        case create
        case edit(HostProfile)
        case quickConnect

        var isQuick: Bool {
            if case .quickConnect = self { return true }
            return false
        }
    }

    var onSave: ((HostProfile, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let mode: Mode
    private let theme: TerminalTheme
    private var glass: GlassBackgroundView?
    private let groups: [HostGroup]
    private let preferredGroupID: UUID?

    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let usernameField = NSTextField()
    private let authPopUp = HandPopUpButton()
    private let keyPathField = NSTextField()
    private let notesField = NSTextField()
    private let groupPopup = HandPopUpButton()
    private let rememberCheckbox = ThemedCheckbox(title: "记住密码")
    private let errorLabel: NSTextField
    private let hintLabel: NSTextField
    private let footerNote: NSTextField
    private var keyRow = NSStackView()
    private var nameRow = NSStackView()
    private var notesRow = NSStackView()
    private var rememberRow = NSStackView()
    private var groupRow = NSStackView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let saveButton: NSButton

    init(theme: TerminalTheme, mode: Mode, groups: [HostGroup] = [], preferredGroupID: UUID? = nil) {
        self.theme = theme
        self.mode = mode
        self.groups = groups
        self.preferredGroupID = preferredGroupID
        titleLabel = UIFactory.label("", size: 20, weight: .semibold, color: theme.foreground)
        subtitleLabel = UIFactory.label("", size: 12, weight: .regular, color: theme.subtle)
        errorLabel = UIFactory.wrappingLabel("", size: 11, color: NSColor(srgbRed: 0.95, green: 0.42, blue: 0.42, alpha: 1))
        hintLabel = UIFactory.wrappingLabel(
            mode.isQuick
                ? "连接时将提示输入密码，或解锁所选私钥。"
                : "密码在连接时输入；私钥口令仅在需要时询问。",
            size: 11,
            color: theme.subtle
        )
        footerNote = UIFactory.label(
            mode.isQuick ? "不会保存主机档案" : "凭据仅保存在本机",
            size: 10,
            weight: .regular,
            color: theme.subtle.withAlphaComponent(0.7)
        )
        saveButton = UIFactory.button("保存", target: nil, action: nil, color: theme.accent, textColor: .white)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 580, height: mode.isQuick ? 400 : 480)
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
        glass = GlassBackgroundView.installDialogBackdrop(in: root)

        let badge = SymbolBadgeView(
            symbol: mode.isQuick ? "bolt.fill" : "server.rack",
            background: theme.accent.withAlphaComponent(0.18),
            tint: theme.accent,
            size: 36
        )
        switch mode {
        case .create:
            titleLabel.stringValue = "新建主机"
            subtitleLabel.stringValue = "保存后双击左侧主机即可在新标签页中连接。"
        case .edit(let profile):
            titleLabel.stringValue = "编辑主机"
            subtitleLabel.stringValue = profile.displayName
        case .quickConnect:
            titleLabel.stringValue = "快速连接"
            subtitleLabel.stringValue = "不保存主机档案，适合临时访问。"
        }
        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        let header = NSStackView(views: [badge, titleStack, NSView()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        configureFields()
        nameRow = makeRow(label: "名称", control: nameField)
        let hostRow = makeRow(label: "主机", control: hostField)
        let portRow = makePortRow()
        let usernameRow = makeRow(label: "用户名", control: usernameField)
        let authRow = makeRow(label: "认证方式", control: authPopUp)
        keyRow = makeKeyRow()
        groupRow = makeRow(label: "分组", control: groupPopup)
        notesRow = makeRow(label: "备注", control: notesField)
        rememberRow = makeRememberRow()
        let form = NSStackView(views: [nameRow, hostRow, portRow, usernameRow, authRow, keyRow, groupRow, notesRow, rememberRow])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)
        form.setHuggingPriority(.defaultHigh, for: .vertical)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hintLabel)

        let divider = HairlineView(color: theme.border)
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        errorLabel.isHidden = true
        root.addSubview(errorLabel)

        let cancel = UIFactory.button("取消", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.keyEquivalent = "\r"
        if mode.isQuick {
            saveButton.title = "连接"
        }
        let buttons = NSStackView(views: [cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        footerNote.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerNote)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),

            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            form.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),

            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            hintLabel.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 10),

            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            divider.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 14),
            divider.heightAnchor.constraint(equalToConstant: 1),

            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            errorLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: errorLabel.bottomAnchor, constant: 10),

            footerNote.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footerNote.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            footerNote.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -16)
        ])

        applyTheme()
        updateAuthUI()
        populate()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeGlassBacked()
        let target: NSTextField = {
            if case .edit = mode { return hostField }
            return hostField
        }()
        view.window?.makeFirstResponder(target)
        updateAuthUI()
    }

    private func configureFields() {
        for field in [nameField, hostField, usernameField, keyPathField, notesField] {
            field.font = .systemFont(ofSize: 13)
            field.bezelStyle = .roundedBezel
            field.controlSize = .regular
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        portField.font = .systemFont(ofSize: 13)
        portField.bezelStyle = .roundedBezel
        portField.controlSize = .regular
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.heightAnchor.constraint(equalToConstant: 26).isActive = true

        nameField.placeholderString = "例如：生产服务器"
        hostField.placeholderString = "example.com 或 192.168.1.10"
        portField.placeholderString = "22"
        usernameField.placeholderString = "用户名"
        keyPathField.placeholderString = "~/.ssh/id_ed25519"
        keyPathField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        notesField.placeholderString = "可选"

        authPopUp.addItems(withTitles: HostAuth.allCases.map(\.title))
        authPopUp.target = self
        authPopUp.action = #selector(authChanged)
        authPopUp.translatesAutoresizingMaskIntoConstraints = false

        groupPopup.addItem(withTitle: "未分组")
        groupPopup.item(at: 0)?.representedObject = nil
        for group in groups {
            let item = NSMenuItem(title: group.displayName, action: nil, keyEquivalent: "")
            item.representedObject = group.id
            groupPopup.menu?.addItem(item)
        }
        groupPopup.translatesAutoresizingMaskIntoConstraints = false
        groupPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        keyPathField.widthAnchor.constraint(equalToConstant: 292).isActive = true
        hostField.widthAnchor.constraint(equalToConstant: 392).isActive = true
        nameField.widthAnchor.constraint(equalToConstant: 392).isActive = true
        usernameField.widthAnchor.constraint(equalToConstant: 392).isActive = true
        notesField.widthAnchor.constraint(equalToConstant: 392).isActive = true

        rememberCheckbox.contentTintColor = theme.foreground
        rememberCheckbox.titleColor = theme.foreground
        rememberCheckbox.font = .systemFont(ofSize: 12)
        rememberCheckbox.state = .off
    }

    private func makeRow(label: String, control: NSView) -> NSStackView {
        let labelView = UIFactory.label(label, size: 12, weight: .medium, color: theme.subtle, alignment: .right)
        labelView.widthAnchor.constraint(equalToConstant: 68).isActive = true
        labelView.alignment = .right
        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makePortRow() -> NSStackView {
        let labelView = UIFactory.label("端口", size: 12, weight: .medium, color: theme.subtle, alignment: .right)
        labelView.widthAnchor.constraint(equalToConstant: 68).isActive = true
        portField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let hint = UIFactory.label("默认 22", size: 11, weight: .regular, color: theme.subtle.withAlphaComponent(0.7))
        let row = NSStackView(views: [labelView, portField, hint])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeKeyRow() -> NSStackView {
        let browse = UIFactory.button("选择…", target: self, action: #selector(browseKeyPressed))
        browse.controlSize = .regular
        let labelView = UIFactory.label("私钥", size: 12, weight: .medium, color: theme.subtle, alignment: .right)
        labelView.widthAnchor.constraint(equalToConstant: 68).isActive = true
        let row = NSStackView(views: [labelView, keyPathField, browse])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeRememberRow() -> NSStackView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 68).isActive = true
        let row = NSStackView(views: [spacer, rememberCheckbox])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func populate() {
        switch mode {
        case .create:
            hostField.stringValue = ""
            usernameField.stringValue = NSUserName()
            portField.stringValue = "22"
            authPopUp.selectItem(at: 0)
            if FileManager.default.fileExists(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519")) {
                keyPathField.stringValue = "~/.ssh/id_ed25519"
            }
        case .edit(let existing):
            nameField.stringValue = existing.name
            hostField.stringValue = existing.host
            portField.stringValue = "\(existing.port)"
            usernameField.stringValue = existing.username
            authPopUp.selectItem(at: existing.auth == .privateKey ? 1 : 0)
            keyPathField.stringValue = existing.privateKeyPath
            notesField.stringValue = existing.notes
            rememberCheckbox.state = existing.rememberSecret ? .on : .off
        case .quickConnect:
            hostField.stringValue = ""
            usernameField.stringValue = NSUserName()
            portField.stringValue = "22"
            authPopUp.selectItem(at: 0)
        }
        let targetGroup: UUID?
        switch mode {
        case .edit(let existing):
            targetGroup = existing.groupID
        case .create, .quickConnect:
            targetGroup = preferredGroupID
        }
        selectGroup(targetGroup)
        updateAuthUI()
    }

    private func selectGroup(_ id: UUID?) {
        if let id, let index = groupPopup.itemArray.firstIndex(where: { ($0.representedObject as? UUID) == id }) {
            groupPopup.selectItem(at: index)
        } else {
            groupPopup.selectItem(at: 0)
        }
    }

    private var selectedGroupID: UUID? {
        let index = groupPopup.indexOfSelectedItem
        guard index > 0, index < groupPopup.numberOfItems else { return nil }
        return groupPopup.item(at: index)?.representedObject as? UUID
    }

    @objc private func authChanged() {
        updateAuthUI()
    }

    private func updateAuthUI() {
        let isKey = authPopUp.indexOfSelectedItem == 1
        keyRow.isHidden = !isKey
        rememberCheckbox.title = isKey ? "记住私钥口令" : "记住密码"
        if mode.isQuick {
            rememberRow.isHidden = true
            nameRow.isHidden = true
            notesRow.isHidden = true
            groupRow.isHidden = true
        } else {
            rememberRow.isHidden = false
            nameRow.isHidden = false
            notesRow.isHidden = false
            groupRow.isHidden = false
        }
        if isKey, keyPathField.stringValue.isEmpty {
            let defaultKey = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519")
            if FileManager.default.fileExists(atPath: defaultKey) {
                keyPathField.stringValue = "~/.ssh/id_ed25519"
            }
        }
        errorLabel.isHidden = true
    }

    private func applyTheme() {
        titleLabel.textColor = theme.foreground
        subtitleLabel.textColor = theme.subtle
        glass?.applyDialog(theme: theme)
        saveButton.bezelColor = theme.accent
    }

    @objc private func browseKeyPressed() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let sshDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        panel.directoryURL = URL(fileURLWithPath: sshDirectory)
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let home = NSHomeDirectory()
            var path = url.path
            if path.hasPrefix(home + "/") {
                path = "~" + path.dropFirst(home.count)
            }
            self.keyPathField.stringValue = path
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        NSSound.beep()
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func savePressed() {
        var profile: HostProfile
        switch mode {
        case .create:
            profile = HostProfile()
        case .edit(let existing):
            profile = existing
        case .quickConnect:
            profile = HostProfile(isTemporary: true)
        }

        profile.name = nameField.stringValue
        profile.host = hostField.stringValue
        profile.username = usernameField.stringValue
        profile.auth = authPopUp.indexOfSelectedItem == 1 ? .privateKey : .password
        profile.privateKeyPath = keyPathField.stringValue
        profile.notes = notesField.stringValue
        profile.rememberSecret = mode.isQuick ? false : rememberCheckbox.state == .on
        profile.groupID = mode.isQuick ? nil : selectedGroupID

        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            showError("端口必须是 1–65535 之间的数字。")
            return
        }
        profile.port = port
        profile.normalize()

        guard !profile.host.isEmpty else {
            showError("请输入主机地址。")
            hostField.becomeFirstResponder()
            return
        }
        guard !profile.username.isEmpty else {
            showError("请输入用户名。")
            usernameField.becomeFirstResponder()
            return
        }
        if profile.auth == .privateKey {
            guard !profile.privateKeyPath.isEmpty else {
                showError("请选择私钥文件。")
                return
            }
            do {
                let inspection = try SSHKeyLoader.inspect(text: keyTextForValidation(profile))
                guard inspection.algorithm == "ssh-ed25519" || inspection.algorithm == "ssh-rsa" else {
                    showError("暂不支持 \(inspection.algorithm) 私钥，请使用 Ed25519 或 RSA 私钥。")
                    return
                }
            } catch {
                showError(error.localizedDescription)
                return
            }
        }
        guard !mode.isQuick else {
            onSave?(profile, false)
            return
        }
        onSave?(profile, true)
    }

    /// The key file, or, on a Mac without it, the copy that came through sync
    /// for this host as long as the key path was not changed.
    private func keyTextForValidation(_ profile: HostProfile) throws -> String {
        do {
            return try SSHKeyLoader.readKey(path: profile.privateKeyPath)
        } catch {
            if case .edit(let existing) = mode, existing.auth == .privateKey,
               existing.privateKeyPath == profile.privateKeyPath,
               let stored = CredentialStore.load(account: PrivateKeyVault.account(for: existing)) {
                return stored
            }
            throw error
        }
    }
}
