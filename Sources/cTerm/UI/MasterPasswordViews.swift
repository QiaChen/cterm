import AppKit

/// Creating, entering and changing the master password that encrypts the
/// local credential file. Shown in its own window at launch (create / unlock)
/// and as a sheet from Settings (change).
final class MasterPasswordViewController: NSViewController {
    enum Mode {
        case create
        case unlock
        case change
    }

    /// Called once the store is unlocked (create, unlock) or re-keyed (change).
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private var mode: Mode
    private let theme: TerminalTheme
    /// Why the password is asked for now, shown above the usual explanation.
    private let reason: String?
    /// In a sheet the dismiss button cancels; in the launch window it quits.
    private let inSheet: Bool
    private let currentField = NSSecureTextField()
    private let field = NSSecureTextField()
    private let confirmField = NSSecureTextField()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let strengthLabel: NSTextField
    private let errorLabel: NSTextField
    private let spinner = NSProgressIndicator()
    private var submitButton: NSButton!
    private var cancelButton: NSButton!
    private let forgotButton = HandCursorButton()
    private var busy = false

    init(mode: Mode, theme: TerminalTheme, reason: String? = nil, inSheet: Bool = false) {
        self.mode = mode
        self.theme = theme
        self.reason = reason
        self.inSheet = inSheet
        titleLabel = UIFactory.label("", size: 18, weight: .semibold, color: theme.foreground)
        detailLabel = UIFactory.wrappingLabel("", size: 11, color: theme.subtle)
        strengthLabel = UIFactory.label("", size: 11, weight: .medium, color: theme.subtle)
        errorLabel = UIFactory.wrappingLabel("", size: 11, color: NSColor(srgbRed: 0.95, green: 0.42, blue: 0.42, alpha: 1))
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = size(for: mode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func size(for mode: Mode) -> NSSize {
        var size = Self.baseSize(for: mode)
        if reason != nil { size.height += 6 }
        return size
    }

    static func baseSize(for mode: Mode) -> NSSize {
        switch mode {
        case .create: return NSSize(width: 460, height: 360)
        case .unlock: return NSSize(width: 460, height: 270)
        case .change: return NSSize(width: 460, height: 370)
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        view = root
        GlassBackgroundView.installDialogBackdrop(in: root).applyDialog(theme: theme)

        let badge = SymbolBadgeView(symbol: "lock.fill", background: theme.accent.withAlphaComponent(0.18),
                                    tint: theme.accent, size: 38)

        let placeholders: [(NSSecureTextField, String)] = [
            (currentField, "当前主密码"), (field, "主密码"), (confirmField, "再次输入主密码")
        ]
        for (input, placeholder) in placeholders {
            input.placeholderString = placeholder
            input.font = .systemFont(ofSize: 13)
            input.bezelStyle = .roundedBezel
            input.translatesAutoresizingMaskIntoConstraints = false
            input.heightAnchor.constraint(equalToConstant: 28).isActive = true
            input.target = self
            input.action = #selector(submitPressed)
        }
        field.delegate = self
        errorLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        forgotButton.isBordered = false
        forgotButton.title = "忘记主密码？"
        forgotButton.font = .systemFont(ofSize: 11)
        forgotButton.contentTintColor = theme.accent
        forgotButton.target = self
        forgotButton.action = #selector(forgotPressed)
        cancelButton = UIFactory.button("", target: self, action: #selector(cancelPressed))
        cancelButton.keyEquivalent = "\u{1b}"
        submitButton = UIFactory.button("", target: self, action: #selector(submitPressed),
                                        color: theme.accent, textColor: .white)
        submitButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [forgotButton, NSView(), spinner, cancelButton, submitButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [badge, titleLabel, detailLabel, currentField, field, confirmField,
                                        strengthLabel, errorLabel])
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
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            currentField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            confirmField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 12)
        ])
        applyMode()
    }

    private func applyMode() {
        switch mode {
        case .create:
            titleLabel.stringValue = "创建主密码"
            detailLabel.stringValue = "主密码用于加密本机保存的服务器密码、私钥口令、私钥副本和云同步凭据，创建后每次启动 cTerm 时输入一次。它只保存在你的记忆里，与同步密码相互独立。忘记主密码只能清除本机凭据（可从云同步恢复）。"
            submitButton.title = "创建"
            cancelButton.title = inSheet ? "取消" : "退出"
        case .unlock:
            titleLabel.stringValue = "解锁 cTerm"
            detailLabel.stringValue = "输入主密码以解锁本机保存的密码与私钥。"
            submitButton.title = "解锁"
            cancelButton.title = inSheet ? "取消" : "退出"
        case .change:
            titleLabel.stringValue = "修改主密码"
            detailLabel.stringValue = "本机凭据文件会用新主密码重新加密。同步密码不受影响。"
            submitButton.title = "修改"
            cancelButton.title = "取消"
        }
        if let reason {
            detailLabel.stringValue = reason + "\n" + detailLabel.stringValue
        }
        currentField.isHidden = mode != .change
        confirmField.isHidden = mode == .unlock
        strengthLabel.isHidden = mode == .unlock
        forgotButton.isHidden = mode != .unlock || inSheet
        field.placeholderString = mode == .change ? "新主密码" : "主密码"
        confirmField.placeholderString = mode == .change ? "再次输入新主密码" : "再次输入主密码"
        field.stringValue = ""
        confirmField.stringValue = ""
        errorLabel.isHidden = true
        updateStrength()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeGlassBacked()
        view.window?.makeFirstResponder(mode == .change ? currentField : field)
    }

    private func updateStrength() {
        let value = field.stringValue
        guard !value.isEmpty else {
            strengthLabel.stringValue = "密码强度：—"
            strengthLabel.textColor = theme.subtle
            return
        }
        let result = SyncPasswordViewController.strength(of: value)
        strengthLabel.stringValue = "密码强度：\(result.title)"
        strengthLabel.textColor = [theme.ansiColor(1), theme.ansiColor(3), theme.ansiColor(3), theme.ansiColor(2)][result.score]
    }

    private func setBusy(_ value: Bool) {
        busy = value
        value ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        for control in [submitButton, cancelButton, forgotButton] as [NSControl] {
            control.isEnabled = !value
        }
        for input in [currentField, field, confirmField] {
            input.isEnabled = !value
        }
    }

    private func fail(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        NSSound.beep()
    }

    @objc private func submitPressed() {
        guard !busy else { return }
        let password = field.stringValue
        guard !password.isEmpty else { return fail("请输入主密码。") }
        if mode != .unlock {
            if SyncPasswordViewController.strength(of: password).score == 0 {
                return fail("主密码至少需要 \(CloudSyncManager.minimumPasswordLength) 位。")
            }
            if password != confirmField.stringValue { return fail("两次输入的密码不一致。") }
        }
        let mode = self.mode
        let current = currentField.stringValue
        setBusy(true)
        errorLabel.isHidden = true
        Task {
            // Key derivation takes a moment; keep the window responsive.
            let result: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    switch mode {
                    case .create: try CredentialStore.setUp(password: password)
                    case .unlock: try CredentialStore.unlock(password: password)
                    case .change: try CredentialStore.changePassword(current: current, to: password)
                    }
                    return nil
                } catch {
                    return error
                }
            }.value
            setBusy(false)
            if let result {
                fail((result as? LocalizedError)?.errorDescription ?? result.localizedDescription)
                (mode == .change ? currentField : field).selectText(nil)
            } else {
                onDone?()
            }
        }
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func forgotPressed() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "清除本机凭据并重设主密码？"
        alert.informativeText = "本机保存的服务器密码、私钥口令、私钥副本、同步密码和 OneDrive 授权都会被删除，主机列表会保留。\n\n如果开启过云同步，设置新主密码后在设置中重新输入同步密码并登录 OneDrive，即可从云端恢复。"
        alert.addButton(withTitle: "清除并重设")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            CredentialStore.resetAll()
            self.mode = .create
            self.preferredContentSize = self.size(for: .create)
            window.setContentSize(self.size(for: .create))
            self.applyMode()
            window.makeFirstResponder(self.field)
        }
    }
}

extension MasterPasswordViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateStrength()
        errorLabel.isHidden = true
    }
}

/// Asks for the master password the first time something is about to be
/// saved: a host, cloud sync, or a remembered password. Until then cTerm runs
/// without one; quick connections never save anything and never ask.
enum MasterPasswordGate {
    /// True once credentials can be saved; false if the user cancelled.
    @MainActor
    static func ensureReady(from presenter: NSViewController, theme: TerminalTheme, reason: String) async -> Bool {
        let mode: MasterPasswordViewController.Mode
        switch CredentialStore.state {
        case .unlocked: return true
        case .needsSetup: mode = .create
        case .locked: mode = .unlock
        }
        return await withCheckedContinuation { continuation in
            let controller = MasterPasswordViewController(mode: mode, theme: theme, reason: reason, inSheet: true)
            controller.onDone = { [weak presenter, weak controller] in
                if let controller { presenter?.dismiss(controller) }
                continuation.resume(returning: true)
            }
            controller.onCancel = { [weak presenter, weak controller] in
                if let controller { presenter?.dismiss(controller) }
                continuation.resume(returning: false)
            }
            presenter.presentAsSheet(controller)
        }
    }
}

/// The window shown at launch when a master password exists (unlock), or when
/// an older build left unencrypted credentials behind (create, to encrypt them).
final class UnlockWindowController: NSWindowController, NSWindowDelegate {
    private var finished = false
    private let onUnlocked: () -> Void

    init(theme: TerminalTheme, onUnlocked: @escaping () -> Void) {
        self.onUnlocked = onUnlocked
        let migrating = CredentialStore.state == .needsSetup
        let controller = MasterPasswordViewController(
            mode: migrating ? .create : .unlock,
            theme: theme,
            reason: migrating ? "本机有旧版本保存的未加密密码，请创建主密码来加密它们。" : nil
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "cTerm"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.makeGlassBacked()
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(controller.preferredContentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        controller.onDone = { [weak self] in self?.finish() }
        controller.onCancel = { NSApp.terminate(nil) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func finish() {
        finished = true
        onUnlocked()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window without unlocking quits: nothing works locked.
        if !finished { NSApp.terminate(nil) }
    }
}
