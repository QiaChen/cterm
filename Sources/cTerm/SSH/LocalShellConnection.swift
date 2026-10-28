import Darwin
import Foundation

/// The user's login shell on this Mac, in a pseudo-terminal.
///
/// The shell is started as a login shell (`-zsh`) in the home folder, so the
/// user's profile files run. An app opened from the Dock inherits almost no
/// environment, so TERM, the locale and TERM_PROGRAM are set here.
@MainActor
final class LocalShellConnection {
    private(set) var state: SSHSessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((SSHSessionState) -> Void)?
    var onData: ((Data) -> Void)?
    var onEnd: ((String?) -> Void)?

    let shellPath: String
    private var cols: Int
    private var rows: Int
    private var master: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let writeQueue = DispatchQueue(label: "cterm.local-shell.write")
    private var didFinish = false

    init(cols: Int, rows: Int, shellPath: String = LocalShellConnection.loginShell) {
        self.cols = max(2, cols)
        self.rows = max(1, rows)
        self.shellPath = shellPath
    }

    /// The account's login shell, as Terminal.app picks it.
    nonisolated static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    var shellName: String {
        (shellPath as NSString).lastPathComponent
    }

    /// The shell's working directory, read from the kernel, so it is right
    /// even when the prompt doesn't report it.
    var currentDirectory: String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    func connect() {
        guard state == .idle else { return }
        state = .connecting

        // Everything the child needs is built before fork: after fork only
        // async-signal-safe calls (chdir, execve, _exit) are made.
        let home = NSHomeDirectory()
        let argv = CStringArray(["-" + shellName]) // leading dash: login shell
        let envp = CStringArray(Self.environment().map { "\($0.key)=\($0.value)" })
        let path = strdup(shellPath)
        let directory = strdup(home)
        defer {
            free(path)
            free(directory)
        }

        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var masterFD: Int32 = -1
        let child = forkpty(&masterFD, nil, nil, &size)
        if child == 0 {
            _ = chdir(directory)
            execve(path, argv.pointers, envp.pointers)
            _exit(127)
        }
        guard child > 0 else {
            let reason = String(cString: strerror(errno))
            state = .failed("无法启动本地 shell：\(reason)")
            onEnd?("无法启动本地 shell：\(reason)")
            didFinish = true
            return
        }

        pid = child
        master = masterFD
        startReading()
        watchExit()
        state = .connected
    }

    func send(_ data: Data) {
        guard state == .connected, master >= 0, !data.isEmpty else { return }
        let fd = master
        // A large paste can fill the pty buffer; write off the main thread,
        // in order, retrying partial writes.
        writeQueue.async {
            data.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written > 0 {
                        remaining -= written
                        pointer = pointer.advanced(by: written)
                    } else if written < 0, errno == EINTR || errno == EAGAIN {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        self.cols = max(2, cols)
        self.rows = max(1, rows)
        guard master >= 0 else { return }
        // The kernel sends SIGWINCH to the foreground job.
        var size = winsize(ws_row: UInt16(self.rows), ws_col: UInt16(self.cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Closes the terminal: the shell and the job in front get SIGHUP, as when
    /// a Terminal.app window is closed.
    func disconnect() {
        guard !didFinish else { return }
        if pid > 0 { kill(pid, SIGHUP) }
        finish(message: "已关闭本地终端")
    }

    // MARK: - Output and exit

    private func startReading() {
        let fd = master
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self, weak source] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                DispatchQueue.main.async { self?.onData?(data) }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                // EOF / EIO: every process holding the terminal has gone.
                source?.cancel()
                DispatchQueue.main.async { self?.shellEnded() }
            }
        }
        // The descriptor is closed only once no read can still be running.
        source.setCancelHandler { close(fd) }
        source.resume()
        readSource = source
    }

    private func watchExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            // Let the last output (an exit message, say) arrive first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { self?.shellEnded() }
            }
        }
        source.resume()
        exitSource = source
    }

    private func shellEnded() {
        guard !didFinish else { return }
        var status: Int32 = 0
        let reaped = pid > 0 && waitpid(pid, &status, WNOHANG) == pid
        var message = "Shell 已退出"
        if reaped {
            let code = (status >> 8) & 0xFF
            if status & 0x7F == 0, code != 0 { message += "（退出码 \(code)）" }
            pid = 0
        }
        finish(message: message)
    }

    private func finish(message: String) {
        guard !didFinish else { return }
        didFinish = true
        // Cancelling the read source closes the descriptor, which also hangs
        // up the terminal for anything still attached to it.
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        master = -1
        if pid > 0 {
            // Reap in the background so no zombie is left.
            let child = pid
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                waitpid(child, &status, 0)
            }
            pid = 0
        }
        state = .disconnected
        onEnd?(message)
    }

    // MARK: - Environment

    nonisolated static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "cTerm"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        env["SHELL"] = loginShell
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["USER"] = env["USER"] ?? NSUserName()
        env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
        if (env["LANG"] ?? "").isEmpty, (env["LC_ALL"] ?? "").isEmpty, (env["LC_CTYPE"] ?? "").isEmpty {
            env["LANG"] = utf8Locale()
        }
        // Variables describing the app's own launch mean nothing to a shell.
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS"] {
            env[key] = nil
        }
        return env
    }

    /// "zh_CN.UTF-8" for a Chinese system, if macOS has that locale.
    nonisolated static func utf8Locale() -> String {
        let locale = Locale.current
        if let language = locale.language.languageCode?.identifier,
           let region = locale.region?.identifier {
            let name = "\(language)_\(region).UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)") { return name }
        }
        return "en_US.UTF-8"
    }
}

extension LocalShellConnection: TerminalConnection {}

/// A NULL-terminated `char *[]` that outlives a fork.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() {
            pointers[index] = strdup(string)
        }
        pointers[count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}
