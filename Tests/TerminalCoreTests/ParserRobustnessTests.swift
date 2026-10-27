import XCTest
@testable import TerminalCore

/// Byte streams that once left the parser swallowing output, printing
/// garbage or leaking style. Each ends with plain text that must appear.
final class ParserRobustnessTests: XCTestCase {
    private func run(_ input: String, cols: Int = 30) -> Terminal {
        let term = Terminal(columns: cols, rows: 5, scrollbackLimit: 10)
        term.feed(input)
        return term
    }

    func testUnterminatedOSCEndsAtNextEscapeSequence() {
        // A title cut off (program killed) must not eat what follows.
        let term = run("\u{1B}]0;half a title\u{1B}[1;1Hok")
        XCTAssertEqual(term.lineText(line: 0), "ok")
    }

    func testUnterminatedDCSEndsAtNextEscapeSequence() {
        let term = run("\u{1B}Pzz\u{1B}[1;1Hok")
        XCTAssertEqual(term.lineText(line: 0), "ok")
    }

    func testCancelAbortsSequences() {
        XCTAssertEqual(run("\u{1B}[12\u{18}ok").lineText(line: 0), "ok")
        XCTAssertEqual(run("\u{1B}]0;title\u{1A}ok").lineText(line: 0), "ok")
        XCTAssertEqual(run("\u{1B}Pdata\u{18}ok").lineText(line: 0), "ok")
    }

    func testApplicationProgramCommandIsNotPrinted() {
        // kitty graphics / tmux use APC; PM and SOS are the same kind of string.
        XCTAssertEqual(run("\u{1B}_Gf=24,s=1;AAAA\u{1B}\\ok").lineText(line: 0), "ok")
        XCTAssertEqual(run("\u{1B}^private\u{1B}\\ok").lineText(line: 0), "ok")
        XCTAssertEqual(run("\u{1B}Xstring\u{1B}\\ok").lineText(line: 0), "ok")
    }

    func testEscapeWithIntermediateConsumesFinalByte() {
        XCTAssertEqual(run("\u{1B} Fok").lineText(line: 0), "ok")    // S7C1T
        XCTAssertEqual(run("\u{1B}-Aok").lineText(line: 0), "ok")    // G1 = Latin-1
        XCTAssertEqual(run("\u{1B}(Bok").lineText(line: 0), "ok")
    }

    func testControlCharacterInsideCSIIsExecuted() {
        // CR in the middle of CUP: the CR acts, the sequence still completes.
        let term = run("abc\u{1B}[1\r;3Hx")
        XCTAssertEqual(term.lineText(line: 0), "abx")
    }

    func testTruncatedUTF8DoesNotEatNextCharacter() {
        let term = Terminal(columns: 30, rows: 5, scrollbackLimit: 10)
        term.feed(bytes: [0xE7, 0x9B] + Array("ok".utf8)) // 目 cut after two bytes
        XCTAssertEqual(term.lineText(line: 0), "\u{FFFD}ok")
    }

    func testIncompleteExtendedColorDoesNotTurnIntoOtherAttributes() {
        let term = run("\u{1B}[38;5mx")
        XCTAssertEqual(term.currentAttributes, [], "the 5 of 38;5 is not blink")
        let term2 = run("\u{1B}[48;2;10mx")
        XCTAssertEqual(term2.currentAttributes, [])
    }

    func testRandomBytesNeverCrashOrStick() {
        // Whatever came before, the next escape sequence must be understood:
        // its answer proves the parser is back in its ground state.
        // (Checking printed text instead is unreliable: random input may
        // switch charsets, insert mode or a 2-column width.)
        var generator = SystemRandomNumberGenerator()
        for run in 0..<300 {
            let term = Terminal(columns: 40, rows: 10, scrollbackLimit: 50)
            var replies = 0
            term.onReply = { _ in replies += 1 }
            let bytes = (0..<2_000).map { _ in UInt8.random(in: 0...255, using: &generator) }
            term.feed(bytes: bytes)
            term.resize(columns: Int.random(in: 2...60), rows: Int.random(in: 1...20))
            term.feed(bytes: bytes.reversed())
            replies = 0
            term.feed("\u{1B}[6n") // no CAN: the next ESC alone must recover
            XCTAssertEqual(replies, 1, "parser stuck after random input (run \(run))")
        }
    }

}

extension ParserRobustnessTests {
    func testDoubledEscapeStartsAgain() {
        XCTAssertEqual(run("\u{1B}\u{1B}[1;1Hok").lineText(line: 0), "ok")
        XCTAssertEqual(run("\u{1B}]0;cut\u{1B}\u{1B}[1;1Hok").lineText(line: 0), "ok")
        XCTAssertEqual(run("\u{1B}(\u{1B}[1;1Hok").lineText(line: 0), "ok")
    }
}
