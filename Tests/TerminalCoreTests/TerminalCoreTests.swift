import XCTest
@testable import TerminalCore

final class TerminalCoreTests: XCTestCase {
    private func makeTerminal(_ text: String = "", cols: Int = 20, rows: Int = 5, scrollback: Int = 100) -> Terminal {
        let terminal = Terminal(columns: cols, rows: rows, scrollbackLimit: scrollback)
        if !text.isEmpty { terminal.feed(text) }
        return terminal
    }

    func testBasicTextAndNewline() {
        let term = makeTerminal("hello\r\nworld")
        XCTAssertEqual(term.lineText(line: 0), "hello")
        XCTAssertEqual(term.lineText(line: 1), "world")
        XCTAssertEqual(term.cursorRow, 1)
        XCTAssertEqual(term.cursorCol, 5)
        XCTAssertEqual(term.totalLineCount, 5)
    }

    func testAutoWrapDefersUntilNextCharacter() {
        let term = makeTerminal("abcde", cols: 5, rows: 4)
        XCTAssertEqual(term.lineText(line: 0), "abcde")
        XCTAssertEqual(term.cursorRow, 0)
        XCTAssertEqual(term.cursorCol, 4)
        term.feed("f")
        XCTAssertEqual(term.lineText(line: 0), "abcde")
        XCTAssertEqual(term.lineText(line: 1), "f")
        XCTAssertEqual(term.cursorRow, 1)
        XCTAssertEqual(term.cursorCol, 1)
        XCTAssertTrue(term.isWrapped(line: 0))
    }

    func testCarriageReturnAndBackspace() {
        let term = makeTerminal("abc\rX")
        XCTAssertEqual(term.lineText(line: 0), "Xbc")
        term.feed("yz\u{8}Q")
        XCTAssertEqual(term.lineText(line: 0), "XyQ")
    }

    func testTabStops() {
        let term = makeTerminal("\tx", cols: 20)
        XCTAssertEqual(term.lineText(line: 0), "        x")
        XCTAssertEqual(term.cursorCol, 9)
    }

    func testSGRColorsAndAttributes() {
        let term = makeTerminal("\u{1B}[1;31mR\u{1B}[0mN")
        let red = term.cell(line: 0, column: 0)
        XCTAssertEqual(red.text, "R")
        XCTAssertEqual(red.fg, .indexed(1))
        XCTAssertTrue(red.attributes.contains(.bold))
        let normal = term.cell(line: 0, column: 1)
        XCTAssertEqual(normal.fg, .default)
        XCTAssertFalse(normal.attributes.contains(.bold))

        term.feed("\u{1B}[38;5;196mX\u{1B}[48;2;10;20;30mY")
        XCTAssertEqual(term.cell(line: 0, column: 2).fg, .indexed(196))
        XCTAssertEqual(term.cell(line: 0, column: 3).bg, .rgb(TermRGB(r: 10, g: 20, b: 30)))

        term.feed("\u{1B}[38:2::1:2:3mZ")
        XCTAssertEqual(term.cell(line: 0, column: 4).fg, .rgb(TermRGB(r: 1, g: 2, b: 3)))
    }

    func testUnderlineDoubleUnderlineAndReset() {
        let term = makeTerminal("\u{1B}[4mU\u{1B}[4:2mD\u{1B}[24mN")
        XCTAssertTrue(term.cell(line: 0, column: 0).attributes.contains(.underline))
        XCTAssertTrue(term.cell(line: 0, column: 1).attributes.contains(.doubleUnderline))
        XCTAssertFalse(term.cell(line: 0, column: 2).attributes.contains(.underline))
    }

    func testCursorMovementAndEraseLine() {
        let term = makeTerminal("hello\r\nworld")
        term.feed("\u{1B}[2;3H\u{1B}[K")
        XCTAssertEqual(term.lineText(line: 1), "wo")
        term.feed("\u{1B}[2J")
        XCTAssertEqual(term.lineText(line: 0), "")
        XCTAssertEqual(term.lineText(line: 1), "")
    }

    func testInsertAndDeleteCharacters() {
        let term = makeTerminal("abcdef", cols: 10)
        term.feed("\u{1B}[1;3H\u{1B}[2@")
        XCTAssertEqual(term.lineText(line: 0), "ab  cdef")
        term.feed("\u{1B}[2P")
        XCTAssertEqual(term.lineText(line: 0), "abcdef")
    }

    func testScrollbackOnFullScreenScroll() {
        let term = makeTerminal("1\r\n2\r\n3\r\n4", cols: 10, rows: 3)
        XCTAssertEqual(term.scrollbackCount, 1)
        XCTAssertEqual(term.lineText(line: 0), "1")
        XCTAssertEqual(term.lineText(line: 1), "2")
        XCTAssertEqual(term.lineText(line: 2), "3")
        XCTAssertEqual(term.lineText(line: 3), "4")
        XCTAssertEqual(term.totalLineCount, 4)
    }

    func testAlternateScreenRestoresMainScreen() {
        let term = makeTerminal("main", cols: 20, rows: 4)
        term.feed("\u{1B}[?1049h")
        XCTAssertTrue(term.isAlternateScreen)
        XCTAssertEqual(term.scrollbackCount, 0)
        XCTAssertEqual(term.lineText(line: 0), "")
        term.feed("alt")
        XCTAssertEqual(term.lineText(line: 0), "alt")
        term.feed("\u{1B}[?1049l")
        XCTAssertFalse(term.isAlternateScreen)
        XCTAssertEqual(term.lineText(line: 0), "main")
        XCTAssertEqual(term.cursorCol, 4)
    }

    func testOSCTitleAndWorkingDirectory() {
        let term = makeTerminal()
        var title: String?
        var cwd: String?
        term.onTitleChange = { title = $0 }
        term.onWorkingDirectoryChange = { cwd = $0 }
        term.feed("\u{1B}]0;My Server\u{7}")
        term.feed("\u{1B}]7;file://localhost/tmp\u{1B}\\")
        XCTAssertEqual(title, "My Server")
        XCTAssertEqual(term.title, "My Server")
        XCTAssertEqual(cwd, "/tmp")
    }

    func testWideCharactersAndCombiningMarks() {
        let term = makeTerminal("你a", cols: 10)
        let wide = term.cell(line: 0, column: 0)
        XCTAssertEqual(wide.text, "你")
        XCTAssertEqual(wide.width, 2)
        XCTAssertTrue(term.cell(line: 0, column: 1).isContinuation)
        XCTAssertEqual(term.cell(line: 0, column: 2).text, "a")
        XCTAssertEqual(term.cursorCol, 3)

        term.feed("\u{1B}[1;1H")
        term.feed("e\u{301}")
        XCTAssertEqual(term.cell(line: 0, column: 0).text, "e\u{301}")
        XCTAssertEqual(term.cursorCol, 1)
    }

    func testDeviceStatusReport() {
        let term = makeTerminal()
        var reply: Data?
        term.onReply = { reply = $0 }
        term.feed("\u{1B}[6n")
        XCTAssertEqual(reply.map { String(decoding: $0, as: UTF8.self) }, "\u{1B}[1;1R")
    }

    func testDECSpecialGraphics() {
        let term = makeTerminal("\u{1B}(0lqk")
        XCTAssertEqual(term.lineText(line: 0), "┌─┐")
    }

    func testBracketedPasteAndCursorKeysModes() {
        let term = makeTerminal()
        term.feed("\u{1B}[?2004h\u{1B}[?1h")
        XCTAssertTrue(term.bracketedPaste)
        XCTAssertTrue(term.applicationCursorKeys)
        term.feed("\u{1B}[?2004l\u{1B}[?1l")
        XCTAssertFalse(term.bracketedPaste)
        XCTAssertFalse(term.applicationCursorKeys)
    }

    func testScrollRegionAndOriginMode() {
        let term = makeTerminal("1\r\n2\r\n3\r\n4\r\n5", cols: 10, rows: 5)
        term.feed("\u{1B}[2;4r\u{1B}[?6h\u{1B}[1;1H")
        XCTAssertEqual(term.cursorRow, 1)
        term.feed("X")
        XCTAssertEqual(term.cell(line: 0, column: 0).text, "1")
        XCTAssertEqual(term.cell(line: 1, column: 0).text, "X")
        XCTAssertEqual(term.cursorRow, 1)
        XCTAssertEqual(term.cursorCol, 1)
        term.feed("\u{1B}[?6l")
        XCTAssertEqual(term.cursorRow, 0)
    }

    func testResizeClampsAndPads() {
        let term = makeTerminal("abcdef\r\nghijkl", cols: 10, rows: 4)
        term.resize(columns: 5, rows: 2)
        XCTAssertEqual(term.cols, 5)
        XCTAssertEqual(term.rows, 2)
        XCTAssertEqual(term.lineText(line: 0), "abcde")
        XCTAssertEqual(term.lineText(line: 1), "ghijk")
        XCTAssertLessThan(term.cursorCol, 5)
        term.resize(columns: 8, rows: 4)
        XCTAssertEqual(term.cols, 8)
        XCTAssertEqual(term.rows, 4)
        XCTAssertEqual(term.lineText(line: 0), "abcde")
    }

    func testDeleteLinesAndInsertLines() {
        let term = makeTerminal("1\r\n2\r\n3\r\n4", cols: 10, rows: 4)
        term.feed("\u{1B}[2;1H\u{1B}[1M")
        XCTAssertEqual(term.lineText(line: 0), "1")
        XCTAssertEqual(term.lineText(line: 1), "3")
        XCTAssertEqual(term.lineText(line: 2), "4")
        term.feed("\u{1B}[2;1H\u{1B}[1L")
        XCTAssertEqual(term.lineText(line: 1), "")
        XCTAssertEqual(term.lineText(line: 2), "3")
    }

    func testClearScrollback() {
        let term = makeTerminal("1\r\n2\r\n3\r\n4", cols: 10, rows: 2)
        XCTAssertGreaterThan(term.scrollbackCount, 0)
        term.clearScrollback()
        XCTAssertEqual(term.scrollbackCount, 0)
        XCTAssertEqual(term.totalLineCount, term.rows)
    }

    func testRepeatCharacter() {
        let term = makeTerminal("x\u{1B}[3b")
        XCTAssertEqual(term.lineText(line: 0), "xxxx")
    }

    func testEscapeResetClearsScreenAndModes() {
        let term = makeTerminal("hello\u{1B}[?1049h")
        term.feed("\u{1B}c")
        XCTAssertFalse(term.isAlternateScreen)
        XCTAssertEqual(term.lineText(line: 0), "")
        XCTAssertEqual(term.cursorRow, 0)
        XCTAssertEqual(term.cursorCol, 0)
    }

    func testVimKeyboardSequencesDoNotChangeStyle() {
        // What vim 9 sends around a session: alternate screen, modifyOtherKeys
        // on/off and the kitty keyboard query.
        let term = makeTerminal("$ ", cols: 20, rows: 5)
        term.feed("\u{1B}[?1049h\u{1B}[>4;2m\u{1B}[?u\u{1B}[1;3r\u{1B}[7mvim\u{1B}[0m")
        XCTAssertEqual(term.currentAttributes, [])
        term.feed("\u{1B}[r\u{1B}[?1049l\u{1B}[>4;m")
        XCTAssertFalse(term.isAlternateScreen)
        XCTAssertEqual(term.currentAttributes, [], "CSI > 4 ; m must not turn on underline")
        XCTAssertEqual(term.cursorRow, 0)
        XCTAssertEqual(term.cursorCol, 2)
        term.feed("ok")
        XCTAssertEqual(term.lineText(line: 0), "$ ok")
        XCTAssertEqual(term.cell(line: 0, column: 2).attributes, [])
    }

    func testPrivateVariantsOfStandardSequencesAreIgnored() {
        let term = makeTerminal("ab", cols: 20, rows: 5)
        term.feed("\u{1B}7")                // save cursor at column 2
        term.feed("\u{1B}[3;5H")
        term.feed("\u{1B}[?u")              // kitty query, not "restore cursor"
        XCTAssertEqual(term.cursorRow, 2)
        XCTAssertEqual(term.cursorCol, 4)
        term.feed("\u{1B}[?2;4r")           // XTRESTORE, not a scroll region
        XCTAssertEqual(term.scrollTop, 0)
        XCTAssertEqual(term.scrollBottom, 4)
        term.feed("\u{1B}[>1m")             // not bold
        XCTAssertEqual(term.currentAttributes, [])
        term.feed("\u{1B}[1m")              // plain SGR still works
        XCTAssertTrue(term.currentAttributes.contains(.bold))
    }
}

extension TerminalCoreTests {
    func testResetModesRecoversFromKilledFullScreenProgram() {
        // vim killed mid-session: alternate screen, hidden cursor, keypad and
        // a scroll region left behind.
        let term = makeTerminal("$ vim\r\n", cols: 20, rows: 5)
        term.feed("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?1h\u{1B}=\u{1B}[2;4r\u{1B}[1;31mx")
        term.resetModes()
        XCTAssertFalse(term.isAlternateScreen)
        XCTAssertTrue(term.cursorVisible)
        XCTAssertFalse(term.applicationCursorKeys)
        XCTAssertEqual(term.scrollTop, 0)
        XCTAssertEqual(term.scrollBottom, 4)
        XCTAssertEqual(term.currentAttributes, [])
        XCTAssertEqual(term.lineText(line: 0), "$ vim", "the shell's text is kept")
    }
}

extension TerminalCoreTests {
    func testChineseWithC1LookalikeBytesIsPrintedNotParsed() {
        // 目 = E7 9B AE (0x9B = 8-bit CSI), 运 = E8 BF 90 (0x90 = DCS),
        // 服 = E6 9C 8D (0x9C = ST); none of them may start or end a sequence.
        let term = makeTerminal("## 目录\r\n1. 运行环境\r\n服务器\r\n", cols: 20, rows: 5)
        XCTAssertEqual(term.lineText(line: 0), "## 目录")
        XCTAssertEqual(term.lineText(line: 1), "1. 运行环境")
        XCTAssertEqual(term.lineText(line: 2), "服务器")
    }

    func testFullScreenSessionWithChineseExitsCleanly() {
        // vim drawing a Chinese line, then quitting.
        let term = makeTerminal("$ ", cols: 20, rows: 5)
        term.feed("\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[35m## 目录\u{1B}[m\r\n1. 运行\u{1B}[?25h\u{1B}[?1049l")
        XCTAssertFalse(term.isAlternateScreen)
        XCTAssertTrue(term.cursorVisible)
        XCTAssertEqual(term.currentAttributes, [])
        XCTAssertEqual(term.currentForeground, .default)
        XCTAssertEqual(term.lineText(line: 0), "$") // trailing blanks are trimmed
        XCTAssertEqual(term.cursorCol, 2)
    }

    func testTitleWithChineseIsNotCutShort() {
        let term = makeTerminal(cols: 20, rows: 5)
        term.feed("\u{1B}]0;root@服务器: ~\u{07}ok")
        XCTAssertEqual(term.title, "root@服务器: ~")
        XCTAssertEqual(term.lineText(line: 0), "ok")
    }
}
