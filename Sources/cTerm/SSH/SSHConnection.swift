import Citadel
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSH

enum SSHSessionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .connecting: return true
        default: return false
        }
    }
}

@MainActor
final class SSHConnection {
    /// One shared event loop for all sessions. Creating a new
    /// MultiThreadedEventLoopGroup per connection leaks threads across
    /// reconnects.
    private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let profile: HostProfile
    private let authentication: SSHAuthenticationMethod
    private let hostKeyValidator: HostKeyValidationDelegate
    private let initialCols: Int
    private let initialRows: Int

    private(set) var state: SSHSessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((SSHSessionState) -> Void)?
    var onData: ((Data) -> Void)?
    var onEnd: ((String?) -> Void)?
    var onError: ((Error) -> Void)?

    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var runTask: Task<Void, Never>?
    private var intentionalClose = false
    private var terminalCols: Int
    private var terminalRows: Int
    private var didFinish = false
    private var writeTask: Task<Void, Never>?

    init(profile: HostProfile,
         authentication: SSHAuthenticationMethod,
         hostKeyValidator: HostKeyValidationDelegate,
         cols: Int,
         rows: Int) {
        self.profile = profile
        self.authentication = authentication
        self.hostKeyValidator = hostKeyValidator
        self.initialCols = max(2, cols)
        self.initialRows = max(1, rows)
        self.terminalCols = max(2, cols)
        self.terminalRows = max(1, rows)
    }

    func connect() {
        guard state == .idle else { return }
        state = .connecting

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await SSHClient.connect(
                    host: self.profile.host,
                    port: self.profile.port,
                    authenticationMethod: self.authentication,
                    hostKeyValidator: .custom(self.hostKeyValidator),
                    reconnect: .never,
                    protocolOptions: [],
                    group: SSHConnection.eventLoopGroup,
                    connectTimeout: .seconds(20)
                )

                if Task.isCancelled || self.intentionalClose {
                    try? await client.close()
                    return
                }
                self.client = client

                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: self.terminalCols,
                    terminalRowHeight: self.terminalRows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1])
                )

                try await client.withPTY(request) { inbound, writer in
                    await MainActor.run {
                        self.writer = writer
                        self.state = .connected
                    }
                    // Make sure a resize that happened while connecting is
                    // applied before the remote shell draws its prompt.
                    let cols = await MainActor.run { self.terminalCols }
                    let rows = await MainActor.run { self.terminalRows }
                    try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)

                    for try await event in inbound {
                        switch event {
                        case .stdout(let buffer):
                            let data = Data(buffer.readableBytesView)
                            if !data.isEmpty {
                                await MainActor.run { self.onData?(data) }
                            }
                        case .stderr(let buffer):
                            let data = Data(buffer.readableBytesView)
                            if !data.isEmpty {
                                await MainActor.run { self.onData?(data) }
                            }
                        }
                    }
                }

                try? await client.close()
                await MainActor.run {
                    self.writer = nil
                    self.client = nil
                    if !self.intentionalClose {
                        self.finish(message: "远程会话已结束")
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.cleanupAfterFailure()
                    if !self.intentionalClose {
                        self.finish(message: "连接已取消")
                    }
                }
            } catch {
                await MainActor.run {
                    if self.intentionalClose { return }
                    self.cleanupAfterFailure()
                    if error is HostKeyRejected {
                        self.state = .failed("已取消：未信任该主机密钥")
                        self.onEnd?("主机密钥未通过验证")
                        self.didFinish = true
                    } else if let commandFailed = error as? SSHClient.CommandFailed {
                        self.finish(message: "远程会话已结束（退出码 \(commandFailed.exitCode)）")
                    } else {
                        self.state = .failed(SSHErrorMessage.describe(error))
                        self.onError?(error)
                        self.onEnd?(SSHErrorMessage.describe(error))
                        self.didFinish = true
                    }
                }
            }
        }
    }

    func send(_ data: Data) {
        guard let writer, !data.isEmpty else { return }
        let buffer = ByteBuffer(data: data)
        // Key events and paste chunks can arrive in the same run loop turn.
        // Chain writes so the remote shell always receives them in order.
        let previous = writeTask
        writeTask = Task { [weak self] in
            await previous?.value
            guard let self, self.writer != nil else { return }
            do {
                try await writer.write(buffer)
            } catch {
                NSLog("cTerm: write failed: \(error)")
            }
        }
    }

    func send(text: String) {
        send(Data(text.utf8))
    }

    /// Opens an SFTP channel on the already authenticated connection, so the
    /// file panel needs no second login or host key check.
    func openSFTP() async throws -> SFTPClient {
        guard state == .connected, let client else {
            throw SFTPUnavailable()
        }
        // Citadel logs every request at info level; keep only problems.
        var logger = Logger(label: "cterm.sftp")
        logger.logLevel = .warning
        return try await client.openSFTP(logger: logger)
    }

    /// Runs a command on its own exec channel beside the shell, for file
    /// operations SFTP has no request for (chmod, archives).
    func runCommand(_ command: String) async throws -> RemoteCommandResult {
        guard state == .connected, let client else {
            throw SFTPUnavailable()
        }
        var stdout = ByteBuffer()
        var stderr = ByteBuffer()
        var exitCode: Int32 = 0
        do {
            for try await chunk in try await client.executeCommandStream(command) {
                switch chunk {
                case .stdout(var buffer): stdout.writeBuffer(&buffer)
                case .stderr(var buffer): stderr.writeBuffer(&buffer)
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            exitCode = Int32(truncatingIfNeeded: failed.exitCode)
        }
        return RemoteCommandResult(exitCode: exitCode,
                                   output: String(buffer: stdout),
                                   errorOutput: String(buffer: stderr))
    }

    func resize(cols: Int, rows: Int) {
        let newCols = max(2, cols)
        let newRows = max(1, rows)
        guard newCols != terminalCols || newRows != terminalRows else { return }
        terminalCols = newCols
        terminalRows = newRows
        guard let writer else { return }
        Task {
            try? await writer.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    func disconnect() {
        guard !didFinish else { return }
        intentionalClose = true
        didFinish = true
        runTask?.cancel()
        writeTask?.cancel()
        writeTask = nil
        if let client {
            Task { try? await client.close() }
        }
        writer = nil
        client = nil
        state = .disconnected
        onEnd?("已断开连接")
    }

    private func cleanupAfterFailure() {
        writeTask?.cancel()
        writeTask = nil
        writer = nil
        if let client {
            self.client = nil
            Task { try? await client.close() }
        }
    }

    private func finish(message: String) {
        guard !didFinish else { return }
        didFinish = true
        writeTask?.cancel()
        writeTask = nil
        writer = nil
        state = .disconnected
        onEnd?(message)
    }
}

struct SFTPUnavailable: LocalizedError {
    var errorDescription: String? { "SSH 会话未连接。" }
}

enum SSHErrorMessage {
    static func describe(_ error: Error) -> String {
        if error is HostKeyRejected {
            return "主机密钥未通过验证，连接已取消。"
        }
        if let clientError = error as? SSHClientError {
            switch clientError {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                return "认证失败：请检查用户名、密码或私钥。"
            case .channelCreationFailed:
                return "无法创建远程会话，服务器可能不允许 Shell 访问。"
            }
        }
        if error is AuthenticationFailed {
            return "认证失败：用户名或凭据不正确。"
        }
        if let sshError = error as? NIOSSHError {
            let description = String(describing: sshError.type)
            if description.contains("keyExchangeNegotiationFailure") {
                return "与服务器没有共同支持的加密算法，请在服务器端启用现代 SSH 算法。"
            }
            if description.contains("invalidExchangeHashSignature") {
                return "主机密钥校验失败，连接可能不安全。"
            }
            if description.contains("tcpShutdown") {
                return "服务器关闭了连接。"
            }
            return "SSH 协议错误：\(sshError.description)"
        }
        // NIO's connection errors carry the cause (refused, timed out, …) in
        // their description; localizedDescription is a generic sentence.
        let text = error.localizedDescription + " " + String(describing: error)
        if text.localizedCaseInsensitiveContains("refused") {
            return "连接被拒绝：请检查主机、端口和防火墙设置。"
        }
        if text.localizedCaseInsensitiveContains("timed out") || text.localizedCaseInsensitiveContains("timeout") {
            return "连接超时：请检查网络或服务器地址。"
        }
        if text.localizedCaseInsensitiveContains("nodename nor servname")
            || text.localizedCaseInsensitiveContains("name or service not known")
            || text.localizedCaseInsensitiveContains("host not found") {
            return "无法解析主机名：请检查主机地址。"
        }
        if text.localizedCaseInsensitiveContains("network is unreachable") {
            return "网络不可达：请检查网络连接。"
        }
        if text.localizedCaseInsensitiveContains("closed") {
            return "连接已关闭：\(text)"
        }
        return error.localizedDescription
    }
}
