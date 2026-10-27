import XCTest
@testable import cTerm

@MainActor
final class LocalShellTests: XCTestCase {
    func testShellRunsCommandsAndReportsExit() throws {
        let shell = LocalShellConnection(cols: 80, rows: 24, shellPath: "/bin/sh")
        var output = ""
        var states: [SSHSessionState] = []
        let ended = expectation(description: "shell ended")
        var endMessage: String?
        shell.onData = { output += String(decoding: $0, as: UTF8.self) }
        shell.onStateChange = { states.append($0) }
        shell.onEnd = { endMessage = $0; ended.fulfill() }

        shell.connect()
        XCTAssertEqual(shell.state, .connected)
        shell.resize(cols: 100, rows: 30)
        shell.send(Data("echo T=$TERM P=$TERM_PROGRAM; stty size; echo sum=$((40+2)); exit 3\n".utf8))
        wait(for: [ended], timeout: 10)

        XCTAssertTrue(output.contains("T=xterm-256color P=cTerm"), output)
        XCTAssertTrue(output.contains("30 100"), "resize reaches the shell: \(output)")
        XCTAssertTrue(output.contains("sum=42"), output)
        XCTAssertEqual(endMessage, "Shell 已退出（退出码 3）")
        XCTAssertEqual(states.last, .disconnected)
    }

    func testDisconnectHangsUpTheShell() throws {
        let shell = LocalShellConnection(cols: 80, rows: 24, shellPath: "/bin/sh")
        var message: String?
        shell.onEnd = { message = $0 }
        shell.connect()
        shell.send(Data("sleep 30\n".utf8))
        shell.disconnect()
        XCTAssertEqual(message, "已关闭本地终端")
        XCTAssertEqual(shell.state, .disconnected)
        shell.send(Data("ignored\n".utf8)) // no crash after close
    }

    func testEnvironmentHasUTF8LocaleAndTerm() {
        let env = LocalShellConnection.environment()
        XCTAssertEqual(env["TERM"], "xterm-256color")
        let locale = env["LC_ALL"] ?? env["LC_CTYPE"] ?? env["LANG"] ?? ""
        XCTAssertFalse(locale.isEmpty)
        XCTAssertTrue(LocalShellConnection.utf8Locale().hasSuffix(".UTF-8"))
    }
}
