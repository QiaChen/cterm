#if DEBUG
import Darwin
import Foundation
import TerminalCore

/// Hidden diagnostic: runs a command in a local pseudo-terminal wired to the
/// terminal emulator exactly like an SSH channel (output in, replies back),
/// types the given keys, and prints the emulator state afterwards.
/// `cTerm --pty-check "<keys>" <command> [args…]`; keys accept \e and \r.
enum PtyCheck {
    static func run(keys: String, command: [String]) -> Never {
        let terminal = Terminal(columns: 80, rows: 24, scrollbackLimit: 1_000)
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            let argv = command.map { strdup($0) } + [nil]
            execvp(command[0], argv)
            _exit(127)
        }
        terminal.onReply = { data in
            data.withUnsafeBytes { _ = write(master, $0.baseAddress, data.count) }
        }

        var received = 0
        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while Date() < end {
                var fds = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&fds, 1, 50) > 0 else { continue }
                let count = read(master, &buffer, buffer.count)
                if count <= 0 { return }
                received += count
                terminal.feed(bytes: Array(buffer[0..<count]))
            }
        }

        pump(1.5)
        let typed = keys.replacingOccurrences(of: "\\e", with: "\u{1B}")
            .replacingOccurrences(of: "\\r", with: "\r")
        for byte in Array(typed.utf8) {
            var value = byte
            _ = write(master, &value, 1)
            pump(0.05)
        }
        pump(1.5)

        var status: Int32 = 0
        var exited = false
        for _ in 0..<20 where !exited {
            exited = waitpid(pid, &status, WNOHANG) == pid
            if !exited { usleep(100_000) }
        }
        if !exited { kill(pid, SIGKILL) }
        print("received=\(received) exited=\(exited) alternate=\(terminal.isAlternateScreen) cursorVisible=\(terminal.cursorVisible) " +
              "cursor=\(terminal.cursorRow),\(terminal.cursorCol) attributes=\(terminal.currentAttributes.rawValue) " +
              "appCursor=\(terminal.applicationCursorKeys) mouse=\(terminal.mouseTracking)")
        for line in 0..<terminal.rows {
            let text = terminal.lineText(line: terminal.totalLineCount - terminal.rows + line)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { print("| \(text)") }
        }
        exit(exited ? 0 : 1)
    }
}
#endif
