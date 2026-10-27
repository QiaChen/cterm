import AppKit
import Citadel
import Foundation
import NIOSSH
import TerminalCore

final class SessionViewController: NSViewController {
    let id = UUID()
    private(set) var profile: HostProfile
    let terminal: Terminal
    let terminalView: TerminalView

    private let knownHosts: KnownHostsStore
    private let overlay: SessionOverlayView
    private var theme: TerminalTheme
    private var connection: (any TerminalConnection)?
    private var started = false
    private var hasConnectedBefore = false
    private var remoteTitle: String?
    private var connectTask: Task<Void, Never>?
    private var demoMode = false
    private var isClosed = false

    var onTitleChanged: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onRequestEdit: (() -> Void)?
    var onRememberSecretChanged: ((Bool) -> Void)?

    private(set) var state: SSHSessionState = .idle

    init(profile: HostProfile, theme: TerminalTheme, knownHosts: KnownHostsStore,
         fontSize: CGFloat = AppearancePreferences.fontSize) {
        self.profile = profile
        self.theme = theme
        self.knownHosts = knownHosts
        self.terminal = Terminal(columns: 80, rows: 24, scrollbackLimit: 8_000)
        self.terminalView = TerminalView(
            terminal: terminal,
            theme: theme,
            fontSize: fontSize
        )
        self.overlay = SessionOverlayView(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root
        terminalView.backgroundOpacity = 0

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(terminalView)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay)

        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: root.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        wireTerminal()
        wireOverlay()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminalView.prepareForConnection()
    }

    private func wireTerminal() {
        terminalView.onSend = { [weak self] data in
            self?.connection?.send(data)
        }
        terminalView.onResize = { [weak self] cols, rows in
            self?.connection?.resize(cols: cols, rows: rows)
        }
        terminal.onBell = {
            NSSound.beep()
        }
        terminal.onReply = { [weak self] data in
            self?.connection?.send(data)
        }
        terminal.onTitleChange = { [weak self] title in
            guard let self else { return }
            self.remoteTitle = title.isEmpty ? nil : title
            self.onTitleChanged?()
        }
    }

    private func wireOverlay() {
        overlay.onCancel = { [weak self] in
            self?.cancelConnecting()
        }
        overlay.onRetry = { [weak self] in
            self?.reconnect()
        }
        overlay.onClose = { [weak self] in
            self?.onRequestClose?()
        }
        overlay.onEdit = { [weak self] in
            self?.onRequestEdit?()
        }
    }

    var tabTitle: String {
        if let remoteTitle, !remoteTitle.isEmpty { return remoteTitle }
        return profile.displayName
    }

    var tabState: SessionTabItem.State {
        switch state {
        case .idle, .connecting: return .connecting
        case .connected: return .connected
        case .failed: return .failed
        case .disconnected: return .disconnected
        }
    }

    var isTemporary: Bool { profile.isTemporary }

    func startIfNeeded() {
        guard !started, !isClosed, !demoMode else { return }
        started = true
        startConnection()
    }

    func prepareForClose() {
        guard !isClosed else { return }
        isClosed = true
        connectTask?.cancel()
        connection?.disconnect()
        connection = nil
        for controller in presentedViewControllers ?? [] {
            dismiss(controller)
        }
    }

    #if DEBUG
    func typeForSnapshot(_ text: String) {
        connection?.send(Data(text.utf8))
    }
    #endif

    func enableDemoMode() {
        demoMode = true
        started = true
        hasConnectedBefore = true
        state = .connected
        terminalView.isInputEnabled = true
        overlay.hideConnecting()
    }

    func loadDemoTranscript(_ transcript: String, remoteTitle title: String) {
        remoteTitle = title
        let normalized = transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        terminal.feed(normalized)
        onTitleChanged?()
    }

    private func startConnection() {
        connectTask?.cancel()
        if profile.isLocal {
            launchLocalShell()
            return
        }
        state = .connecting
        onStateChanged?()
        terminalView.isInputEnabled = false
        overlay.showConnecting(detail: "\(profile.displayName)\n\(profile.endpoint)")

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let authentication = try await self.resolveAuthentication()
                if Task.isCancelled || self.isClosed { return }
                self.launchSSH(authentication: authentication)
            } catch is CancellationError {
                // The view is going away; nothing to do.
            } catch let error as UserCancelledConnection {
                _ = error
                if !self.hasConnectedBefore {
                    self.onRequestClose?()
                } else {
                    self.setDisconnectedOverlay(message: "已取消连接。")
                }
            } catch {
                self.showFailure(error.localizedDescription)
            }
        }
    }

    /// A shell on this Mac: no credentials or host key, nothing to wait for.
    private func launchLocalShell() {
        terminalView.prepareForConnection()
        attach(LocalShellConnection(cols: terminal.cols, rows: terminal.rows))
    }

    private func launchSSH(authentication: SSHAuthenticationMethod) {
        terminalView.prepareForConnection()
        let validator = HostKeyValidationDelegate(
            host: profile.host,
            port: profile.port,
            knownHosts: knownHosts
        ) { [weak self] info in
            guard let self else { return false }
            return await self.confirmHostKey(info)
        }

        let session = SSHConnection(
            profile: profile,
            authentication: authentication,
            hostKeyValidator: validator,
            cols: terminal.cols,
            rows: terminal.rows
        )
        session.onError = { error in
            NSLog("cTerm SSH error: \(error)")
        }
        attach(session)
    }

    private func attach(_ session: any TerminalConnection) {
        self.connection = session

        session.onData = { [weak self, weak session] data in
            guard let self, self.connection === session else { return }
            self.terminal.feed(data)
        }
        session.onStateChange = { [weak self, weak session] state in
            guard let self, self.connection === session else { return }
            self.state = state
            self.handleState(state)
            self.onStateChanged?()
        }
        session.onEnd = { [weak self, weak session] message in
            guard let self, self.connection === session else { return }
            self.handleEnd(message: message)
        }
        session.connect()
    }

    private func handleState(_ state: SSHSessionState) {
        switch state {
        case .idle:
            break
        case .connecting:
            terminalView.isInputEnabled = false
            if !profile.isLocal {
                overlay.showConnecting(detail: "\(profile.displayName)\n\(profile.endpoint)")
            }
        case .connected:
            hasConnectedBefore = true
            terminalView.isInputEnabled = true
            overlay.hideConnecting()
            view.window?.makeFirstResponder(terminalView)
            onTitleChanged?()
        case .failed(let message):
            terminalView.isInputEnabled = false
            if message.contains("认证失败") {
                CredentialStore.delete(account: CredentialStore.account(for: profile.id, kind: "password"))
                CredentialStore.delete(account: CredentialStore.account(for: profile.id, kind: "passphrase"))
                if profile.rememberSecret {
                    profile.rememberSecret = false
                    onRememberSecretChanged?(false)
                }
            }
            overlay.showFailure(
                title: profile.isLocal ? "无法打开本地终端" : "连接失败",
                detail: "\(profile.displayName) · \(profile.endpoint)\n\(message)",
                allowsEdit: !profile.isLocal
            )
            onTitleChanged?()
        case .disconnected:
            terminalView.isInputEnabled = false
        }
    }

    private func handleEnd(message: String?) {
        switch state {
        case .failed:
            break
        case .disconnected:
            setDisconnectedOverlay(message: message ?? "远程会话已结束。")
        default:
            break
        }
    }

    private func setDisconnectedOverlay(message: String) {
        terminalView.isInputEnabled = false
        overlay.showDisconnected(
            detail: "\(profile.displayName) · \(profile.endpoint)\n\(message)",
            title: profile.isLocal ? "本地终端已结束" : "连接已断开",
            retryTitle: profile.isLocal ? "重新打开" : "重新连接"
        )
        onTitleChanged?()
    }

    private func showFailure(_ message: String) {
        state = .failed(message)
        terminalView.isInputEnabled = false
        overlay.showFailure(
            title: "无法连接",
            detail: "\(profile.displayName) · \(profile.endpoint)\n\(message)"
        )
        onStateChanged?()
        onTitleChanged?()
    }

    func reconnect() {
        guard !state.isBusy else { return }
        connectTask?.cancel()
        connection?.disconnect()
        connection = nil
        terminal.reset()
        terminalView.resetViewState()
        terminalView.isInputEnabled = false
        startConnection()
    }

    func disconnect() {
        guard let connection else { return }
        connectTask?.cancel()
        connection.disconnect()
    }

    func updateProfile(_ profile: HostProfile) {
        self.profile = profile
        remoteTitle = nil
        reconnect()
    }

    /// Updates the stored profile without interrupting the current session.
    /// The new settings are used the next time a connection is attempted.
    func refreshProfile(_ profile: HostProfile) {
        self.profile = profile
        onTitleChanged?()
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        view.layer?.backgroundColor = NSColor.clear.cgColor
        terminalView.backgroundOpacity = theme.isDark ? 0 : 0.04
        terminalView.theme = theme
        overlay.apply(theme: theme)
    }

    func applyFontSize() {
        terminalView.fontSize = AppearancePreferences.fontSize
    }

    private func cancelConnecting() {
        connectTask?.cancel()
        connection?.disconnect()
        connection = nil
        if hasConnectedBefore {
            setDisconnectedOverlay(message: "已取消连接。")
        } else {
            onRequestClose?()
        }
    }

    // MARK: - Credentials

    private func resolveAuthentication() async throws -> SSHAuthenticationMethod {
        switch profile.auth {
        case .password:
            #if DEBUG
            if DebugAutomation.matches(profile), let password = DebugAutomation.password {
                return .passwordBased(username: profile.username, password: password)
            }
            #endif
            let account = CredentialStore.account(for: profile.id, kind: "password")
            if profile.rememberSecret, let saved = CredentialStore.load(account: account) {
                return .passwordBased(username: profile.username, password: saved)
            }
            let result = await promptSecret(
                title: "验证身份",
                detail: "\(profile.username)@\(profile.host):\(profile.port)\n请输入登录密码。",
                placeholder: "密码",
                actionTitle: "连接",
                rememberTitle: "记住密码",
                rememberByDefault: profile.rememberSecret
            )
            guard let result else { throw UserCancelledConnection() }
            if result.remember, await canRemember() {
                CredentialStore.save(result.value, account: account)
                profile.rememberSecret = true
                onRememberSecretChanged?(true)
            } else {
                CredentialStore.delete(account: account)
                profile.rememberSecret = false
                onRememberSecretChanged?(false)
            }
            return .passwordBased(username: profile.username, password: result.value)

        case .privateKey:
            let inspection = try SSHKeyLoader.inspect(text: PrivateKeyVault.keyText(for: profile))
            guard inspection.algorithm == "ssh-ed25519" || inspection.algorithm == "ssh-rsa" else {
                throw SSHKeyError.unsupportedAlgorithm(inspection.algorithm)
            }
            if !inspection.isEncrypted {
                return try SSHKeyLoader.authentication(for: profile, passphrase: nil)
            }

            let account = CredentialStore.account(for: profile.id, kind: "passphrase")
            var passphrase: String? = profile.rememberSecret
                ? CredentialStore.load(account: account)
                : nil
            var detail = "该私钥已加密。\n\(profile.privateKeyPath)"
            var attempts = 0
            while attempts < 3 {
                do {
                    let auth = try SSHKeyLoader.authentication(for: profile, passphrase: passphrase)
                    if passphrase != nil, profile.rememberSecret {
                        CredentialStore.save(passphrase!, account: account)
                    }
                    return auth
                } catch SSHKeyError.passphraseRequired {
                    passphrase = nil
                } catch SSHKeyError.invalidPassphrase {
                    passphrase = nil
                    detail = "私钥口令不正确，请重试。\n\(profile.privateKeyPath)"
                } catch {
                    throw error
                }

                let result = await promptSecret(
                    title: "解锁私钥",
                    detail: detail,
                    placeholder: "私钥口令",
                    actionTitle: "解锁并连接",
                    rememberTitle: "记住私钥口令",
                    rememberByDefault: profile.rememberSecret
                )
                guard let result else { throw UserCancelledConnection() }
                passphrase = result.value
                if result.remember, await canRemember() {
                    CredentialStore.save(result.value, account: account)
                    profile.rememberSecret = true
                    onRememberSecretChanged?(true)
                } else {
                    CredentialStore.delete(account: account)
                    profile.rememberSecret = false
                    onRememberSecretChanged?(false)
                }
                attempts += 1
            }
            throw SSHKeyError.invalidPassphrase
        }
    }

    /// Remembering needs the master password; the first time, it is created here.
    private func canRemember() async -> Bool {
        await MasterPasswordGate.ensureReady(
            from: self, theme: theme,
            reason: "记住密码前，请先创建主密码，用来在本机加密保存的密码。"
        )
    }

    private func promptSecret(
        title: String,
        detail: String,
        placeholder: String,
        actionTitle: String,
        rememberTitle: String,
        rememberByDefault: Bool
    ) async -> (value: String, remember: Bool)? {
        guard let window = view.window else { return nil }
        return await withCheckedContinuation { continuation in
            let controller = SecretPromptViewController(
                configuration: .init(
                    title: title,
                    message: profile.displayName,
                    detail: detail,
                    fieldPlaceholder: placeholder,
                    actionTitle: actionTitle,
                    allowsRemembering: !profile.isTemporary,
                    rememberByDefault: rememberByDefault,
                    rememberTitle: rememberTitle
                ),
                theme: theme
            )
            controller.onSubmit = { [weak self, weak controller] value, remember in
                if let controller { self?.dismiss(controller) }
                continuation.resume(returning: (value, remember))
            }
            controller.onCancel = { [weak self, weak controller] in
                if let controller { self?.dismiss(controller) }
                continuation.resume(returning: nil)
            }
            presentAsSheet(controller)
            _ = window
        }
    }

    private func confirmHostKey(_ info: HostKeyInfo) async -> Bool {
        #if DEBUG
        if DebugAutomation.trustHostKey { return true }
        #endif
        guard let window = view.window else { return false }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.icon = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)
            alert.addButton(withTitle: info.isChanged ? "取消" : "信任并连接")
            alert.addButton(withTitle: info.isChanged ? "仍然连接" : "取消")

            if info.isChanged {
                alert.alertStyle = .critical
                alert.messageText = "主机密钥已更改"
                alert.informativeText = """
                无法确认 \(info.host):\(info.port) 是同一台服务器。

                新指纹：
                \(info.fingerprint)
                旧指纹：
                \(info.existing?.fingerprint ?? "—")

                这可能意味着服务器重装，也可能存在中间人攻击。请确认后再继续。
                """
            } else if info.isNewAlgorithm {
                alert.alertStyle = .warning
                alert.messageText = "尝试新的主机密钥类型"
                alert.informativeText = """
                \(info.host):\(info.port) 提供了新的密钥类型 \(info.algorithm)。

                指纹：
                \(info.fingerprint)
                """
            } else {
                alert.alertStyle = .warning
                alert.messageText = "首次连接到此主机"
                alert.informativeText = """
                请确认以下指纹与服务器管理员提供的一致。

                主机：\(info.host):\(info.port)
                类型：\(info.algorithm)
                指纹：\(info.fingerprint)
                """
            }

            alert.beginSheetModal(for: window) { response in
                let accepted: Bool
                if info.isChanged {
                    accepted = response == .alertSecondButtonReturn
                } else {
                    accepted = response == .alertFirstButtonReturn
                }
                continuation.resume(returning: accepted)
            }
        }
    }
}

private struct UserCancelledConnection: Error {}
