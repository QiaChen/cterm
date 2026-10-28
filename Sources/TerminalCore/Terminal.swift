import Foundation

public enum CursorStyle: Equatable, Sendable {
    case block
    case bar
    case underline
}

public enum MouseTrackingMode: Equatable, Sendable {
    case off
    case x10
    case button
    case any
}

/// A VT100/xterm style terminal emulator.
///
/// The emulator owns the character grid, scrollback buffer, cursor and the
/// parser for escape sequences. It is UI agnostic: the AppKit layer reads the
/// grid and feeds bytes received from the pty.
public final class Terminal {
    // MARK: - Geometry

    public private(set) var cols: Int
    public private(set) var rows: Int
    public let scrollbackLimit: Int

    // MARK: - Buffers

    private var screen: [TermLine]
    private var scrollback: [TermLine] = []
    private var savedMainScreen: [TermLine]?
    private var savedMainCursor: SavedCursor?
    private var altBuffer: [TermLine]?
    public private(set) var isAlternateScreen = false

    // MARK: - Cursor

    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0
    public private(set) var cursorVisible = true
    public private(set) var cursorStyle: CursorStyle = .block
    public private(set) var cursorBlink = true
    private var pendingWrap = false
    private var savedCursor: SavedCursor?

    // MARK: - Attributes

    public private(set) var currentForeground: TermColor = .default
    public private(set) var currentBackground: TermColor = .default
    public private(set) var currentAttributes: CellAttributes = []

    // MARK: - Modes

    public private(set) var autoWrap = true
    public private(set) var originMode = false
    public private(set) var insertMode = false
    public private(set) var applicationCursorKeys = false
    public private(set) var applicationKeypad = false
    public private(set) var bracketedPaste = false
    public private(set) var focusReporting = false
    public private(set) var alternateScroll = false
    public private(set) var mouseTracking: MouseTrackingMode = .off
    public private(set) var mouseSGR = false

    public private(set) var scrollTop = 0
    public private(set) var scrollBottom: Int
    private var tabStops: [Bool]

    // MARK: - Metadata

    public private(set) var title: String = ""
    public private(set) var workingDirectory: String?
    public private(set) var paletteOverrides: [UInt8: TermRGB] = [:]
    public private(set) var revision: UInt64 = 0

    // MARK: - Callbacks

    public var onUpdate: (() -> Void)?
    public var onBell: (() -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onWorkingDirectoryChange: ((String) -> Void)?
    /// Used to answer device queries (DSR, DA, ...) by writing to the pty.
    public var onReply: ((Data) -> Void)?

    // MARK: - Parser state

    private enum ParseState {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
        case dcs
        case dcsEscape
        case charset
        case hash
        case percent
    }

    private struct SavedCursor {
        var row: Int
        var col: Int
        var foreground: TermColor
        var background: TermColor
        var attributes: CellAttributes
        var g0DEC: Bool
        var g1DEC: Bool
        var shiftOut: Bool
        var originMode: Bool
        var pendingWrap: Bool

        init(row: Int, col: Int, foreground: TermColor, background: TermColor,
             attributes: CellAttributes, g0DEC: Bool, g1DEC: Bool,
             shiftOut: Bool, originMode: Bool, pendingWrap: Bool) {
            self.row = row
            self.col = col
            self.foreground = foreground
            self.background = background
            self.attributes = attributes
            self.g0DEC = g0DEC
            self.g1DEC = g1DEC
            self.shiftOut = shiftOut
            self.originMode = originMode
            self.pendingWrap = pendingWrap
        }
    }

    private var state: ParseState = .ground
    private var csiBuffer: [UInt8] = []
    private var oscBuffer: [UInt8] = []
    private var charsetSlot: Int = 0
    private var g0DEC = false
    private var g1DEC = false
    private var shiftOut = false
    private var pendingZWJCell: (row: Int, col: Int)?
    private var lastPrintedText: String = ""
    private var lastPrintedWidth: Int = 1
    private var utf8 = UTF8Decoder()
    private var dirty = false

    // MARK: - Init

    public init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = 5_000) {
        let safeColumns = max(2, columns)
        let safeRows = max(1, rows)
        self.cols = safeColumns
        self.rows = safeRows
        self.scrollbackLimit = max(0, scrollbackLimit)
        self.scrollBottom = safeRows - 1
        self.screen = Array(repeating: TermLine(columns: safeColumns), count: safeRows)
        self.tabStops = Terminal.makeDefaultTabStops(columns: safeColumns)
    }

    private static func makeDefaultTabStops(columns: Int) -> [Bool] {
        var stops = Array(repeating: false, count: max(1, columns))
        var column = 8
        while column < columns {
            stops[column] = true
            column += 8
        }
        return stops
    }

    // MARK: - Public queries

    public var scrollbackCount: Int {
        isAlternateScreen ? 0 : scrollback.count
    }

    public var totalLineCount: Int {
        scrollbackCount + rows
    }

    /// Absolute line index of the cursor. In the main buffer line 0 is the
    /// oldest scrollback line.
    public var cursorLine: Int {
        scrollbackCount + cursorRow
    }

    public func line(at index: Int) -> TermLine? {
        if isAlternateScreen {
            guard index >= 0, index < rows else { return nil }
            return screen[index]
        }
        if index >= 0, index < scrollback.count {
            return scrollback[index]
        }
        let row = index - scrollback.count
        guard row >= 0, row < rows else { return nil }
        return screen[row]
    }

    public func cell(line: Int, column: Int) -> Cell {
        guard let termLine = self.line(at: line), column >= 0, column < termLine.cells.count else {
            return .blank
        }
        return termLine.cells[column]
    }

    public func lineText(line: Int) -> String {
        self.line(at: line)?.trimmedText() ?? ""
    }

    public func isWrapped(line: Int) -> Bool {
        self.line(at: line)?.wrapped ?? false
    }

    public func allText() -> String {
        var lines: [String] = []
        let count = totalLineCount
        lines.reserveCapacity(count)
        for index in 0..<count {
            lines.append(lineText(line: index))
        }
        return lines.joined(separator: "\n")
    }

    public func resolvedPaletteOverride(_ index: UInt8) -> TermRGB? {
        paletteOverrides[index]
    }

    // MARK: - Feeding data

    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for offset in 0..<rawBuffer.count {
                process(byte: base[offset])
            }
        }
        flush()
    }

    public func feed(_ string: String) {
        feed(Data(string.utf8))
    }

    public func feed(bytes: [UInt8]) {
        feed(Data(bytes))
    }

    private func process(byte: UInt8) {
        // CAN and SUB abort whatever sequence is in progress (ECMA-48), so a
        // half-received sequence can always be cancelled.
        if state != .ground, byte == 0x18 || byte == 0x1A {
            csiBuffer.removeAll(keepingCapacity: true)
            oscBuffer.removeAll(keepingCapacity: true)
            state = .ground
            return
        }
        switch state {
        case .ground:
            ground(byte)
        case .escape:
            escape(byte)
        case .csi:
            csi(byte)
        case .osc:
            osc(byte)
        case .oscEscape:
            // ESC \ ends the string. Any other ESC means the string was cut
            // off (a killed program, a truncated title): drop it and treat the
            // ESC as the start of the next sequence instead of swallowing
            // everything that follows.
            if byte == 0x5C {
                finishOSC()
            } else {
                oscBuffer.removeAll(keepingCapacity: true)
                state = .escape
                escape(byte)
            }
        case .dcs:
            if byte == 0x1B { state = .dcsEscape }
        case .dcsEscape:
            if byte == 0x5C {
                state = .ground
            } else {
                state = .escape
                escape(byte)
            }
        case .charset where byte == 0x1B, .hash where byte == 0x1B, .percent where byte == 0x1B:
            // These take exactly one more byte; an ESC there starts anew.
            state = .escape
        case .charset:
            switch charsetSlot {
            case 0: g0DEC = byte == 0x30
            case 1: g1DEC = byte == 0x30
            default: break
            }
            state = .ground
        case .hash:
            if byte == 0x38 { alignmentTest() }
            state = .ground
        case .percent:
            state = .ground
        }
    }

    private func ground(_ byte: UInt8) {
        if byte == 0x1B {
            state = .escape
            utf8.reset()
            return
        }
        if byte < 0x20 {
            control(byte)
            utf8.reset()
            return
        }
        if byte == 0x7F {
            return
        }
        // The stream is UTF-8, so 0x80–0x9F are never 8-bit C1 controls: they
        // are continuation bytes of ordinary characters (目 is E7 9B AE, 运 is
        // E8 BF 90). Reading them as CSI/OSC/DCS swallowed the rest of vim's
        // screen, its exit sequence included. Like xterm in UTF-8 mode, C1
        // controls are not interpreted; a decoded U+0080–U+009F is dropped.
        let (scalar, retry) = utf8.feed(byte)
        if let scalar, !(0x80...0x9F).contains(scalar.value) {
            printScalar(scalar)
        }
        // The byte that broke an unfinished sequence starts something new.
        if retry { ground(byte) }
    }

    private func control(_ byte: UInt8) {
        switch byte {
        case 0x07: // BEL
            onBell?()
        case 0x08: // BS
            pendingWrap = false
            cursorCol = max(0, cursorCol - 1)
        case 0x09: // HT
            pendingWrap = false
            tabForward(1)
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            lineFeed()
        case 0x0D: // CR
            pendingWrap = false
            cursorCol = 0
        case 0x0E: // SO, invoke G1
            shiftOut = true
        case 0x0F: // SI, invoke G0
            shiftOut = false
        default:
            break
        }
    }

    private func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case 0x1B: // ESC ESC: the first was abandoned, a new sequence starts
            state = .escape
        case 0x5B: // [
            csiBuffer.removeAll(keepingCapacity: true)
            state = .csi
        case 0x5D: // ]
            oscBuffer.removeAll(keepingCapacity: true)
            state = .osc
        case 0x50: // P DCS
            state = .dcs
        case 0x58, 0x5E, 0x5F: // X SOS, ^ PM, _ APC: strings to ST, ignored like DCS
            state = .dcs
        case 0x28: // (
            charsetSlot = 0
            state = .charset
        case 0x29: // )
            charsetSlot = 1
            state = .charset
        case 0x2A, 0x2B: // * +
            charsetSlot = 2
            state = .charset
        case 0x20, 0x2D, 0x2E, 0x2F: // SP (S7C1T…), - . / (96-character sets)
            charsetSlot = 3 // consumed and ignored
            state = .charset
        case 0x23: // #
            state = .hash
        case 0x25: // %
            state = .percent
        case 0x37: // 7 DECSC
            saveCursor()
        case 0x38: // 8 DECRC
            restoreCursor()
        case 0x44: // D IND
            lineFeed()
        case 0x45: // E NEL
            cursorCol = 0
            lineFeed()
        case 0x4D: // M RI
            reverseIndex()
        case 0x48: // H HTS
            if cursorCol >= 0, cursorCol < tabStops.count { tabStops[cursorCol] = true }
        case 0x4E, 0x4F: // N / O single shift, ignored
            break
        case 0x5A: // Z DECID
            reply("\u{1B}[?1;2c")
        case 0x63: // c RIS
            reset()
        case 0x3D: // = application keypad
            applicationKeypad = true
        case 0x3E: // > numeric keypad
            applicationKeypad = false
        case 0x5C: // ST
            break
        default:
            break
        }
    }

    private func csi(_ byte: UInt8) {
        if byte >= 0x40 && byte <= 0x7E {
            let body = csiBuffer
            csiBuffer.removeAll(keepingCapacity: true)
            state = .ground
            handleCSI(body, final: byte)
            return
        }
        if byte == 0x1B {
            csiBuffer.removeAll(keepingCapacity: true)
            state = .escape
            return
        }
        if byte < 0x20 {
            control(byte) // C0 controls act immediately inside a sequence
            return
        }
        if byte == 0x9C {
            csiBuffer.removeAll(keepingCapacity: true)
            state = .ground
            return
        }
        if csiBuffer.count < 512 {
            csiBuffer.append(byte)
        }
    }

    private func osc(_ byte: UInt8) {
        if byte == 0x07 {
            finishOSC()
            return
        }
        if byte == 0x1B {
            state = .oscEscape
            return
        }
        // No 8-bit ST (0x9C) here: in UTF-8 it is a continuation byte, and a
        // title such as "服务器" (服 is E6 9C 8D) would end the sequence early.
        if oscBuffer.count < 16_384 {
            oscBuffer.append(byte)
        }
    }

    private func finishOSC() {
        let payload = String(decoding: oscBuffer, as: UTF8.self)
        oscBuffer.removeAll(keepingCapacity: true)
        state = .ground
        handleOSC(payload)
    }

    // MARK: - CSI parsing

    private func handleCSI(_ body: [UInt8], final: UInt8) {
        var bytes = body[...]
        var privateMarker: UInt8?
        if let first = bytes.first,
           first == 0x3F || first == 0x3E || first == 0x3C || first == 0x3D {
            privateMarker = first
            bytes = bytes.dropFirst()
        }
        var intermediates: [UInt8] = []
        while let last = bytes.last, last >= 0x20, last <= 0x2F {
            intermediates.insert(last, at: 0)
            bytes = bytes.dropLast()
        }
        let groups = parseParameters(bytes)
        let params = groups.map { $0.first ?? 0 }

        // A private marker or an intermediate byte makes a different control
        // function that only shares the final byte: vim sends CSI > 4 ; 2 m
        // (modifyOtherKeys) on start and CSI > 4 ; m on exit, which read as SGR
        // left the shell underlined, and CSI ? u (kitty keyboard query) read
        // as "restore cursor". Only the variants handled below are accepted.
        if let privateMarker {
            let accepted: Set<UInt8> = privateMarker == 0x3F
                ? [0x4A, 0x4B, 0x68, 0x6C, 0x6E] // DECSED, DECSEL, DECSET, DECRST, DSR
                : [0x63]                          // DA2 / DA3
            guard accepted.contains(final) else { return }
        }
        if !intermediates.isEmpty, ![0x70, 0x71, 0x54].contains(final) { // DECSTR, DECSCUSR, SD
            return
        }

        switch final {
        case 0x40: // @ ICH
            insertCharacters(param(params, 0, default: 1))
        case 0x41: // A CUU
            moveCursor(rowDelta: -param(params, 0, default: 1))
        case 0x42: // B CUD
            moveCursor(rowDelta: param(params, 0, default: 1))
        case 0x43: // C CUF
            moveCursor(colDelta: param(params, 0, default: 1))
        case 0x44: // D CUB
            moveCursor(colDelta: -param(params, 0, default: 1))
        case 0x45: // E CNL
            moveCursor(rowDelta: param(params, 0, default: 1))
            cursorCol = 0
            pendingWrap = false
        case 0x46: // F CPL
            moveCursor(rowDelta: -param(params, 0, default: 1))
            cursorCol = 0
            pendingWrap = false
        case 0x47: // G CHA
            setCursorColumn(param(params, 0, default: 1))
        case 0x48, 0x66: // H / f CUP
            setCursorPosition(
                row: param(params, 0, default: 1),
                column: param(params, 1, default: 1)
            )
        case 0x49: // I CHT
            tabForward(param(params, 0, default: 1))
        case 0x4A: // J ED
            eraseInDisplay(param(params, 0, default: 0))
        case 0x4B: // K EL
            eraseInLine(param(params, 0, default: 0))
        case 0x4C: // L IL
            insertLines(param(params, 0, default: 1))
        case 0x4D: // M DL
            deleteLines(param(params, 0, default: 1))
        case 0x50: // P DCH
            deleteCharacters(param(params, 0, default: 1))
        case 0x53: // S SU
            scrollUp(param(params, 0, default: 1))
        case 0x54: // T SD
            if params.count >= 2 || intermediates.isEmpty {
                scrollDown(param(params, 0, default: 1))
            }
        case 0x58: // X ECH
            eraseCharacters(param(params, 0, default: 1))
        case 0x5A: // Z CBT
            tabBackward(param(params, 0, default: 1))
        case 0x60: // ` HPA
            setCursorColumn(param(params, 0, default: 1))
        case 0x61: // a HPR
            moveCursor(colDelta: param(params, 0, default: 1))
        case 0x62: // b REP
            repeatLastCharacter(param(params, 0, default: 1))
        case 0x63: // c DA
            if privateMarker == 0x3E {
                reply("\u{1B}[>1;10;0c")
            } else if privateMarker == nil {
                reply("\u{1B}[?1;2c")
            }
        case 0x64: // d VPA
            setCursorRow(param(params, 0, default: 1))
        case 0x65: // e VPR
            moveCursor(rowDelta: param(params, 0, default: 1))
        case 0x67: // g TBC
            tabClear(param(params, 0, default: 0))
        case 0x68: // h SM
            setModes(params, privateMarker: privateMarker, enabled: true)
        case 0x6C: // l RM
            setModes(params, privateMarker: privateMarker, enabled: false)
        case 0x6D: // m SGR
            selectGraphicRendition(groups)
        case 0x6E: // n DSR
            deviceStatusReport(params, privateMarker: privateMarker)
        case 0x70: // p
            if intermediates.contains(0x21) { // DECSTR soft reset
                softReset()
            }
        case 0x71: // q DECSCUSR
            if intermediates.contains(0x20) {
                setCursorStyle(param(params, 0, default: 0))
            }
        case 0x72: // r DECSTBM
            setScrollRegion(top: param(params, 0, default: 1), bottom: param(params, 1, default: rows))
        case 0x73: // s SCOSC
            saveCursor()
        case 0x74: // t window ops
            windowOperation(params)
        case 0x75: // u SCORC
            restoreCursor()
        default:
            break
        }
    }

    private func parseParameters(_ bytes: ArraySlice<UInt8>) -> [[Int]] {
        guard !bytes.isEmpty else { return [] }
        var groups: [[Int]] = []
        var current: [Int] = []
        var value = 0
        var hasValue = false

        func flushCurrent() {
            current.append(hasValue ? value : 0)
            value = 0
            hasValue = false
        }

        for byte in bytes {
            switch byte {
            case 0x3B: // ;
                current.append(hasValue ? value : 0)
                groups.append(current)
                current = []
                value = 0
                hasValue = false
            case 0x3A: // :
                current.append(hasValue ? value : 0)
                value = 0
                hasValue = false
            case 0x30...0x39:
                value = min(65535, value * 10 + Int(byte - 0x30))
                hasValue = true
            default:
                break
            }
        }
        if hasValue || !current.isEmpty {
            current.append(hasValue ? value : 0)
            groups.append(current)
        }
        return groups
    }

    private func param(_ params: [Int], _ index: Int, default fallback: Int) -> Int {
        guard index < params.count else { return fallback }
        let value = params[index]
        return value == 0 ? fallback : value
    }

    // MARK: - Screen operations

    private func blankCell(background: TermColor? = nil) -> Cell {
        Cell(
            text: " ",
            fg: .default,
            bg: background ?? currentBackground,
            attributes: [],
            width: 1
        )
    }

    private func blankLine() -> TermLine {
        TermLine(cells: Array(repeating: Cell.blank, count: cols))
    }

    private func clearScrollbackIfNeeded() {
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }
    }

    private func pushScrollback(_ line: TermLine) {
        guard scrollbackLimit > 0 else { return }
        var copy = line
        // Keep `wrapped`: resize reflow and line selection join on it.
        copy.cells.removeLast(copy.cells.count - max(1, Self.usedWidth(copy.cells)))
        scrollback.append(copy)
        clearScrollbackIfNeeded()
        markDirty()
    }

    private func scrollUp(_ count: Int) {
        let amount = max(1, min(count, scrollBottom - scrollTop + 1))
        guard scrollTop >= 0, scrollBottom < rows, scrollTop <= scrollBottom else { return }
        if scrollTop == 0, scrollBottom == rows - 1, !isAlternateScreen {
            for index in 0..<amount {
                pushScrollback(screen[index])
            }
        }
        screen.removeSubrange(scrollTop..<(scrollTop + amount))
        let blanks = Array(repeating: blankLine(), count: amount)
        screen.insert(contentsOf: blanks, at: scrollBottom - amount + 1)
        markDirty()
    }

    private func scrollDown(_ count: Int) {
        let amount = max(1, min(count, scrollBottom - scrollTop + 1))
        guard scrollTop >= 0, scrollBottom < rows, scrollTop <= scrollBottom else { return }
        screen.removeSubrange((scrollBottom - amount + 1)...scrollBottom)
        let blanks = Array(repeating: blankLine(), count: amount)
        screen.insert(contentsOf: blanks, at: scrollTop)
        markDirty()
    }

    private func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
        markDirty()
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
        markDirty()
    }

    private func wrapLine() {
        pendingWrap = false
        screen[cursorRow].wrapped = true
        cursorCol = 0
        lineFeed()
    }

    private func printScalar(_ scalar: Unicode.Scalar) {
        let mapped = mapCharset(scalar)
        let text = String(mapped)
        let width = CharWidth.width(mapped)

        if width == 0 {
            if mapped.value == 0x200D {
                if let location = appendToPreviousCell(text) {
                    pendingZWJCell = location
                }
            } else {
                _ = appendToPreviousCell(text)
            }
            markDirty()
            return
        }

        if let join = pendingZWJCell {
            if join.row >= 0, join.row < screen.count,
               join.col >= 0, join.col < screen[join.row].cells.count {
                screen[join.row].cells[join.col].text += text
                pendingZWJCell = nil
                lastPrintedText = text
                lastPrintedWidth = width
                markDirty()
                return
            }
            pendingZWJCell = nil
        }

        if pendingWrap {
            if autoWrap {
                wrapLine()
            } else {
                pendingWrap = false
            }
        }

        if width == 2, cursorCol >= cols - 1 {
            if autoWrap {
                wrapLine()
            } else {
                cursorCol = max(0, cols - 2)
            }
        }
        if cursorCol + width > cols {
            if autoWrap {
                wrapLine()
            } else {
                cursorCol = max(0, cols - width)
            }
        }

        if insertMode {
            insertCharacters(width)
        }

        cleanWideCharacter(atRow: cursorRow, column: cursorCol)
        if width == 2, cursorCol + 1 < cols {
            cleanWideCharacter(atRow: cursorRow, column: cursorCol + 1)
        }

        let cell = Cell(
            text: text,
            fg: currentForeground,
            bg: currentBackground,
            attributes: currentAttributes,
            width: UInt8(width)
        )
        screen[cursorRow].cells[cursorCol] = cell
        if width == 2, cursorCol + 1 < cols {
            screen[cursorRow].cells[cursorCol + 1] = Cell(
                text: "",
                fg: currentForeground,
                bg: currentBackground,
                attributes: currentAttributes,
                width: 0
            )
        }

        lastPrintedText = text
        lastPrintedWidth = width
        cursorCol += width
        if cursorCol >= cols {
            cursorCol = cols - 1
            pendingWrap = autoWrap
        }
        markDirty()
    }

    private func mapCharset(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let useDEC = shiftOut ? g1DEC : g0DEC
        guard useDEC, scalar.value >= 0x60, scalar.value <= 0x7E,
              let mapped = CharWidth.decSpecialGraphic(UInt8(scalar.value)),
              let first = mapped.unicodeScalars.first else {
            return scalar
        }
        return first
    }

    @discardableResult
    private func appendToPreviousCell(_ text: String) -> (row: Int, col: Int)? {
        let row = cursorRow
        var col = cursorCol
        if pendingWrap {
            col = cols - 1
        } else if col > 0 {
            col -= 1
        } else {
            return nil
        }
        guard row >= 0, row < screen.count, col >= 0, col < screen[row].cells.count else {
            return nil
        }
        if screen[row].cells[col].isContinuation {
            col -= 1
            guard col >= 0 else { return nil }
        }
        let existing = screen[row].cells[col]
        if existing.text.isEmpty || existing.text == " " {
            // A combining mark without a base character: show it on a dotted
            // circle so it is not silently lost.
            screen[row].cells[col] = Cell(
                text: "\u{25CC}" + text,
                fg: currentForeground,
                bg: currentBackground,
                attributes: currentAttributes,
                width: 1
            )
        } else {
            screen[row].cells[col].text += text
        }
        return (row, col)
    }

    private func cleanWideCharacter(atRow row: Int, column: Int) {
        guard row >= 0, row < screen.count,
              column >= 0, column < screen[row].cells.count else { return }
        let existing = screen[row].cells[column]
        if existing.isContinuation, column > 0 {
            screen[row].cells[column - 1] = blankCell(background: .default)
        } else if existing.width == 2, column + 1 < screen[row].cells.count {
            screen[row].cells[column + 1] = blankCell(background: .default)
        }
    }

    private func repeatLastCharacter(_ count: Int) {
        guard !lastPrintedText.isEmpty, count > 0 else { return }
        let repeatCount = min(count, 4096)
        if let scalar = lastPrintedText.unicodeScalars.first,
           lastPrintedText.unicodeScalars.count == 1 {
            for _ in 0..<repeatCount {
                printScalar(scalar)
            }
        } else {
            for _ in 0..<repeatCount {
                for scalar in lastPrintedText.unicodeScalars {
                    printScalar(scalar)
                }
            }
        }
        _ = lastPrintedWidth
    }

    private func insertCharacters(_ count: Int) {
        guard count > 0, cursorRow >= 0, cursorRow < screen.count else { return }
        var cells = screen[cursorRow].cells
        let n = min(count, cols - cursorCol)
        guard n > 0 else { return }
        cells.insert(contentsOf: Array(repeating: blankCell(), count: n), at: cursorCol)
        if cells.count > cols {
            cells.removeLast(cells.count - cols)
        }
        screen[cursorRow].cells = cells
        pendingWrap = false
        markDirty()
    }

    private func deleteCharacters(_ count: Int) {
        guard count > 0, cursorRow >= 0, cursorRow < screen.count else { return }
        var cells = screen[cursorRow].cells
        let n = min(count, cols - cursorCol)
        guard n > 0 else { return }
        cells.removeSubrange(cursorCol..<(cursorCol + n))
        cells.append(contentsOf: Array(repeating: blankCell(), count: n))
        if cells.count > cols {
            cells.removeLast(cells.count - cols)
        }
        screen[cursorRow].cells = cells
        pendingWrap = false
        markDirty()
    }

    private func eraseCharacters(_ count: Int) {
        guard count > 0, cursorRow >= 0, cursorRow < screen.count else { return }
        let end = min(cols, cursorCol + count)
        for column in cursorCol..<end {
            screen[cursorRow].cells[column] = blankCell()
        }
        pendingWrap = false
        markDirty()
    }

    private func eraseInLine(_ mode: Int) {
        guard cursorRow >= 0, cursorRow < screen.count else { return }
        switch mode {
        case 0:
            for column in cursorCol..<cols {
                screen[cursorRow].cells[column] = blankCell()
            }
        case 1:
            for column in 0...min(cursorCol, cols - 1) {
                screen[cursorRow].cells[column] = blankCell()
            }
        case 2:
            for column in 0..<cols {
                screen[cursorRow].cells[column] = blankCell()
            }
        default:
            break
        }
        pendingWrap = false
        markDirty()
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorRow + 1 < rows {
                for row in (cursorRow + 1)..<rows {
                    screen[row] = blankLine()
                }
            }
        case 1:
            eraseInLine(1)
            if cursorRow > 0 {
                for row in 0..<cursorRow {
                    screen[row] = blankLine()
                }
            }
        case 2:
            screen = Array(repeating: blankLine(), count: rows)
        case 3:
            scrollback.removeAll()
        default:
            break
        }
        pendingWrap = false
        markDirty()
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let amount = max(1, min(count, scrollBottom - cursorRow + 1))
        let row = cursorRow
        screen.removeSubrange(row..<row)
        let blanks = Array(repeating: blankLine(), count: amount)
        screen.insert(contentsOf: blanks, at: row)
        // Remove the same amount from the bottom of the scroll region.
        screen.removeSubrange((scrollBottom - amount + 1)...scrollBottom)
        pendingWrap = false
        markDirty()
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let amount = max(1, min(count, scrollBottom - cursorRow + 1))
        screen.removeSubrange(cursorRow..<(cursorRow + amount))
        let blanks = Array(repeating: blankLine(), count: amount)
        screen.insert(contentsOf: blanks, at: scrollBottom - amount + 1)
        pendingWrap = false
        markDirty()
    }

    private func alignmentTest() {
        let fill = Cell(text: "E", fg: currentForeground, bg: currentBackground)
        for row in 0..<rows {
            screen[row].cells = Array(repeating: fill, count: cols)
            screen[row].wrapped = false
        }
        markDirty()
    }

    // MARK: - Cursor movement

    private func cursorRowBounds() -> (min: Int, max: Int) {
        if originMode {
            return (scrollTop, scrollBottom)
        }
        return (0, rows - 1)
    }

    private func clampCursor() {
        let bounds = cursorRowBounds()
        cursorRow = min(max(cursorRow, bounds.min), bounds.max)
        cursorCol = min(max(cursorCol, 0), cols - 1)
    }

    private func moveCursor(rowDelta: Int = 0, colDelta: Int = 0) {
        cursorRow += rowDelta
        cursorCol += colDelta
        clampCursor()
        pendingWrap = false
        markDirty()
    }

    private func setCursorPosition(row: Int, column: Int) {
        let r = max(1, row) - 1
        let c = max(1, column) - 1
        if originMode {
            cursorRow = min(scrollTop + r, scrollBottom)
        } else {
            cursorRow = min(r, rows - 1)
        }
        cursorCol = min(c, cols - 1)
        pendingWrap = false
        markDirty()
    }

    private func setCursorRow(_ row: Int) {
        let r = max(1, row) - 1
        cursorRow = originMode ? min(scrollTop + r, scrollBottom) : min(r, rows - 1)
        pendingWrap = false
        markDirty()
    }

    private func setCursorColumn(_ column: Int) {
        cursorCol = min(max(0, column - 1), cols - 1)
        pendingWrap = false
        markDirty()
    }

    private func tabForward(_ count: Int) {
        var remaining = max(1, count)
        while remaining > 0 {
            if cursorCol >= cols - 1 { break }
            cursorCol += 1
            while cursorCol < cols - 1, !tabStops[cursorCol] {
                cursorCol += 1
            }
            remaining -= 1
        }
        pendingWrap = false
        markDirty()
    }

    private func tabBackward(_ count: Int) {
        var remaining = max(1, count)
        while remaining > 0 {
            if cursorCol <= 0 { break }
            cursorCol -= 1
            while cursorCol > 0, !tabStops[cursorCol] {
                cursorCol -= 1
            }
            remaining -= 1
        }
        pendingWrap = false
        markDirty()
    }

    private func tabClear(_ mode: Int) {
        switch mode {
        case 0:
            if cursorCol < tabStops.count { tabStops[cursorCol] = false }
        case 3:
            for index in tabStops.indices { tabStops[index] = false }
        default:
            break
        }
    }

    private func setScrollRegion(top: Int, bottom: Int) {
        let newTop = max(1, min(top, rows)) - 1
        let newBottom = max(1, min(bottom, rows)) - 1
        guard newTop < newBottom else { return }
        scrollTop = newTop
        scrollBottom = newBottom
        setCursorPosition(row: 1, column: 1)
        pendingWrap = false
        markDirty()
    }

    private func saveCursor() {
        savedCursor = SavedCursor(
            row: cursorRow,
            col: cursorCol,
            foreground: currentForeground,
            background: currentBackground,
            attributes: currentAttributes,
            g0DEC: g0DEC,
            g1DEC: g1DEC,
            shiftOut: shiftOut,
            originMode: originMode,
            pendingWrap: pendingWrap
        )
    }

    private func restoreCursor() {
        guard let saved = savedCursor else { return }
        cursorRow = min(max(0, saved.row), rows - 1)
        cursorCol = min(max(0, saved.col), cols - 1)
        currentForeground = saved.foreground
        currentBackground = saved.background
        currentAttributes = saved.attributes
        g0DEC = saved.g0DEC
        g1DEC = saved.g1DEC
        shiftOut = saved.shiftOut
        originMode = saved.originMode
        pendingWrap = saved.pendingWrap
        markDirty()
    }

    // MARK: - Modes

    private func setModes(_ params: [Int], privateMarker: UInt8?, enabled: Bool) {
        guard privateMarker == 0x3F else {
            for mode in params {
                switch mode {
                case 4:
                    insertMode = enabled
                case 20:
                    break
                default:
                    break
                }
            }
            return
        }
        for mode in params {
            switch mode {
            case 1:
                applicationCursorKeys = enabled
            case 6:
                originMode = enabled
                cursorRow = enabled ? scrollTop : 0
                cursorCol = 0
                pendingWrap = false
            case 7:
                autoWrap = enabled
            case 12:
                cursorBlink = enabled
            case 25:
                cursorVisible = enabled
            case 47:
                if enabled { enterAlternateScreen(clear: false) } else { exitAlternateScreen(clear: false) }
            case 1000:
                mouseTracking = enabled ? .x10 : .off
            case 1002:
                mouseTracking = enabled ? .button : .off
            case 1003:
                mouseTracking = enabled ? .any : .off
            case 1004:
                focusReporting = enabled
            case 1006:
                mouseSGR = enabled
            case 1007:
                alternateScroll = enabled
            case 1047:
                if enabled { enterAlternateScreen(clear: true) } else { exitAlternateScreen(clear: true) }
            case 1048:
                if enabled { saveCursor() } else { restoreCursor() }
            case 1049:
                if enabled { enterAlternateScreen(clear: true) } else { exitAlternateScreen(clear: false) }
            case 2004:
                bracketedPaste = enabled
            case 9, 1005, 1015, 2026:
                break
            default:
                break
            }
        }
        markDirty()
    }

    private func enterAlternateScreen(clear: Bool) {
        if isAlternateScreen {
            if clear {
                screen = Array(repeating: blankLine(), count: rows)
            }
            cursorRow = 0
            cursorCol = 0
            pendingWrap = false
            markDirty()
            return
        }
        savedMainScreen = screen
        savedMainCursor = SavedCursor(
            row: cursorRow,
            col: cursorCol,
            foreground: currentForeground,
            background: currentBackground,
            attributes: currentAttributes,
            g0DEC: g0DEC,
            g1DEC: g1DEC,
            shiftOut: shiftOut,
            originMode: originMode,
            pendingWrap: pendingWrap
        )
        isAlternateScreen = true
        if clear || altBuffer == nil {
            screen = Array(repeating: blankLine(), count: rows)
        } else {
            screen = altBuffer ?? Array(repeating: blankLine(), count: rows)
        }
        altBuffer = nil
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        markDirty()
    }

    private func exitAlternateScreen(clear: Bool) {
        guard isAlternateScreen else { return }
        altBuffer = clear ? nil : screen
        if let main = savedMainScreen {
            screen = main
        } else {
            screen = Array(repeating: blankLine(), count: rows)
        }
        if let saved = savedMainCursor {
            cursorRow = min(max(0, saved.row), rows - 1)
            cursorCol = min(max(0, saved.col), cols - 1)
            currentForeground = saved.foreground
            currentBackground = saved.background
            currentAttributes = saved.attributes
            g0DEC = saved.g0DEC
            g1DEC = saved.g1DEC
            shiftOut = saved.shiftOut
            originMode = saved.originMode
            pendingWrap = saved.pendingWrap
        }
        savedMainScreen = nil
        savedMainCursor = nil
        isAlternateScreen = false
        markDirty()
    }

    private func setCursorStyle(_ value: Int) {
        switch value {
        case 0, 1:
            cursorStyle = .block
            cursorBlink = true
        case 2:
            cursorStyle = .block
            cursorBlink = false
        case 3:
            cursorStyle = .underline
            cursorBlink = true
        case 4:
            cursorStyle = .underline
            cursorBlink = false
        case 5:
            cursorStyle = .bar
            cursorBlink = true
        case 6:
            cursorStyle = .bar
            cursorBlink = false
        default:
            break
        }
        markDirty()
    }

    private func deviceStatusReport(_ params: [Int], privateMarker: UInt8?) {
        let mode = params.first ?? 0
        switch (privateMarker, mode) {
        case (nil, 5):
            reply("\u{1B}[0n")
        case (nil, 6):
            let row = cursorRow + 1
            let col = cursorCol + 1
            reply("\u{1B}[\(row);\(col)R")
        case (0x3F?, 6):
            let row = cursorRow + 1
            let col = cursorCol + 1
            reply("\u{1B}[?\(row);\(col);1R")
        case (0x3F?, 15):
            reply("\u{1B}[?13n")
        default:
            break
        }
    }

    private func windowOperation(_ params: [Int]) {
        guard let operation = params.first else { return }
        switch operation {
        case 18:
            reply("\u{1B}[8;\(rows);\(cols)t")
        default:
            break
        }
    }

    // MARK: - SGR

    private func selectGraphicRendition(_ groups: [[Int]]) {
        if groups.isEmpty {
            resetAttributes()
            return
        }
        var index = 0
        while index < groups.count {
            let group = groups[index]
            let code = group.first ?? 0
            switch code {
            case 0:
                resetAttributes()
            case 1:
                currentAttributes.insert(.bold)
            case 2:
                currentAttributes.insert(.dim)
            case 3:
                currentAttributes.insert(.italic)
            case 4:
                if group.count > 1 {
                    switch group[1] {
                    case 0: currentAttributes.remove([.underline, .doubleUnderline])
                    case 2: currentAttributes.insert([.underline, .doubleUnderline])
                    default: currentAttributes.insert(.underline)
                    }
                } else {
                    currentAttributes.insert(.underline)
                }
            case 5, 6:
                currentAttributes.insert(.blink)
            case 7:
                currentAttributes.insert(.inverse)
            case 8:
                currentAttributes.insert(.hidden)
            case 9:
                currentAttributes.insert(.strikethrough)
            case 21:
                currentAttributes.insert([.underline, .doubleUnderline])
            case 22:
                currentAttributes.remove([.bold, .dim])
            case 23:
                currentAttributes.remove(.italic)
            case 24:
                currentAttributes.remove([.underline, .doubleUnderline])
            case 25:
                currentAttributes.remove(.blink)
            case 27:
                currentAttributes.remove(.inverse)
            case 28:
                currentAttributes.remove(.hidden)
            case 29:
                currentAttributes.remove(.strikethrough)
            case 30...37:
                currentForeground = .indexed(UInt8(code - 30))
            case 39:
                currentForeground = .default
            case 40...47:
                currentBackground = .indexed(UInt8(code - 40))
            case 49:
                currentBackground = .default
            case 90...97:
                currentForeground = .indexed(UInt8(code - 90 + 8))
            case 100...107:
                currentBackground = .indexed(UInt8(code - 100 + 8))
            case 38, 48, 58:
                let (color, consumed) = parsedExtendedColor(groups: groups, at: index, code: code)
                if let color {
                    if code == 38 {
                        currentForeground = color
                    } else if code == 48 {
                        currentBackground = color
                    }
                }
                index += consumed
            default:
                break
            }
            index += 1
        }
        markDirty()
    }

    private func parsedExtendedColor(groups: [[Int]], at index: Int, code: Int) -> (TermColor?, Int) {
        let group = groups[index]
        // Colon form: 38:5:n or 38:2:r:g:b / 38:2:colorspace:r:g:b
        if group.count >= 3 {
            if group[1] == 5 {
                return (.indexed(UInt8(clamping: group[2])), 0)
            }
            if group[1] == 2 {
                let components = Array(group.suffix(3))
                if components.count == 3 {
                    return (.rgb(TermRGB(
                        r: UInt8(clamping: components[0]),
                        g: UInt8(clamping: components[1]),
                        b: UInt8(clamping: components[2])
                    )), 0)
                }
            }
        }
        // Semicolon form: 38;5;n or 38;2;r;g;b
        if index + 1 < groups.count {
            let mode = groups[index + 1].first ?? 0
            let remaining = groups.count - index - 1
            // Too few values: drop the rest, so 38;5 does not become blink.
            if (mode == 5 && remaining < 2) || (mode == 2 && remaining < 4) {
                return (nil, remaining)
            }
            if mode == 5, index + 2 < groups.count {
                let value = groups[index + 2].first ?? 0
                return (.indexed(UInt8(clamping: value)), 2)
            }
            if mode == 2, index + 4 < groups.count {
                let r = groups[index + 2].first ?? 0
                let g = groups[index + 3].first ?? 0
                let b = groups[index + 4].first ?? 0
                return (.rgb(TermRGB(
                    r: UInt8(clamping: r),
                    g: UInt8(clamping: g),
                    b: UInt8(clamping: b)
                )), 4)
            }
        }
        _ = code
        return (nil, 0)
    }

    private func resetAttributes() {
        currentForeground = .default
        currentBackground = .default
        currentAttributes = []
    }

    // MARK: - OSC

    private func handleOSC(_ payload: String) {
        guard !payload.isEmpty else { return }
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let command = String(parts[0])
        let rest = parts.count > 1 ? String(parts[1]) : ""

        switch command {
        case "0", "1", "2":
            let newTitle = sanitizeTitle(rest)
            if !newTitle.isEmpty, newTitle != title {
                title = newTitle
                onTitleChange?(newTitle)
                markDirty()
            }
        case "4":
            // OSC 4 ; index ; color
            let fields = rest.split(separator: ";", omittingEmptySubsequences: false)
            if fields.count >= 2,
               let index = UInt8(fields[0].trimmingCharacters(in: .whitespaces)),
               let color = parseOSCColor(String(fields[1])) {
                paletteOverrides[index] = color
                markDirty()
            }
        case "7":
            if let path = parseFileURL(rest) {
                workingDirectory = path
                onWorkingDirectoryChange?(path)
                markDirty()
            }
        case "104":
            if rest.isEmpty {
                paletteOverrides.removeAll()
            } else {
                for field in rest.split(separator: ";") {
                    if let index = UInt8(field.trimmingCharacters(in: .whitespaces)) {
                        paletteOverrides.removeValue(forKey: index)
                    }
                }
            }
            markDirty()
        default:
            break
        }
    }

    private func sanitizeTitle(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, 200))
        for character in value {
            if result.count >= 200 { break }
            if let scalar = character.unicodeScalars.first, scalar.value < 0x20 || scalar.value == 0x7F {
                continue
            }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseOSCColor(_ value: String) -> TermRGB? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            if hex.count == 3, let value = UInt16(hex, radix: 16) {
                let r = UInt8((value >> 8) & 0xF) * 17
                let g = UInt8((value >> 4) & 0xF) * 17
                let b = UInt8(value & 0xF) * 17
                return TermRGB(r: r, g: g, b: b)
            }
            if hex.count == 6, let value = UInt32(hex, radix: 16) {
                return TermRGB(
                    r: UInt8((value >> 16) & 0xFF),
                    g: UInt8((value >> 8) & 0xFF),
                    b: UInt8(value & 0xFF)
                )
            }
            return nil
        }
        if trimmed.hasPrefix("rgb:") {
            let components = trimmed.dropFirst(4).split(separator: "/")
            guard components.count == 3 else { return nil }
            func component(_ text: Substring) -> UInt8? {
                guard let raw = UInt32(text, radix: 16) else { return nil }
                let maxValue = (1 << (4 * text.count)) - 1
                if maxValue <= 0 { return 0 }
                return UInt8((raw * 255) / UInt32(maxValue))
            }
            guard let r = component(components[0]),
                  let g = component(components[1]),
                  let b = component(components[2]) else { return nil }
            return TermRGB(r: r, g: g, b: b)
        }
        return nil
    }

    private func parseFileURL(_ value: String) -> String? {
        if let url = URL(string: value), url.isFileURL {
            return url.path
        }
        if value.hasPrefix("file://") {
            let path = String(value.dropFirst("file://".count))
            if let slash = path.firstIndex(of: "/") {
                return String(path[slash...]).removingPercentEncoding ?? String(path[slash...])
            }
        }
        if value.hasPrefix("/") {
            return value
        }
        return nil
    }

    // MARK: - Reset

    /// Recovers from a program that ended without restoring the terminal, for
    /// example vim killed while it had hidden the cursor: leaves the alternate
    /// screen and resets modes, attributes and the parser, keeping the text
    /// and scrollback.
    public func resetModes() {
        if isAlternateScreen { exitAlternateScreen(clear: true) }
        altBuffer = nil
        savedCursor = nil
        state = .ground
        csiBuffer.removeAll(keepingCapacity: true)
        oscBuffer.removeAll(keepingCapacity: true)
        resetAttributes()
        autoWrap = true
        originMode = false
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        bracketedPaste = false
        focusReporting = false
        alternateScroll = false
        mouseTracking = .off
        mouseSGR = false
        cursorVisible = true
        cursorStyle = .block
        cursorBlink = true
        scrollTop = 0
        scrollBottom = rows - 1
        paletteOverrides.removeAll()
        g0DEC = false
        g1DEC = false
        shiftOut = false
        pendingWrap = false
        markDirty()
    }

    public func reset() {
        screen = Array(repeating: TermLine(columns: cols), count: rows)
        scrollback.removeAll()
        savedMainScreen = nil
        savedMainCursor = nil
        altBuffer = nil
        isAlternateScreen = false
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        savedCursor = nil
        resetAttributes()
        autoWrap = true
        originMode = false
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        bracketedPaste = false
        focusReporting = false
        alternateScroll = false
        mouseTracking = .off
        mouseSGR = false
        cursorVisible = true
        cursorStyle = .block
        cursorBlink = true
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Terminal.makeDefaultTabStops(columns: cols)
        paletteOverrides.removeAll()
        g0DEC = false
        g1DEC = false
        shiftOut = false
        pendingZWJCell = nil
        lastPrintedText = ""
        lastPrintedWidth = 1
        utf8.reset()
        markDirty()
    }

    private func softReset() {
        cursorVisible = true
        insertMode = false
        originMode = false
        autoWrap = true
        scrollTop = 0
        scrollBottom = rows - 1
        resetAttributes()
        savedCursor = nil
        cursorStyle = .block
        cursorBlink = true
        pendingWrap = false
        markDirty()
    }

    public func clearScrollback() {
        scrollback.removeAll()
        markDirty()
    }

    /// Clears the visible screen and scrollback, then homes the cursor.
    public func clearBuffer() {
        scrollback.removeAll()
        screen = Array(repeating: blankLine(), count: rows)
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        markDirty()
    }

    // MARK: - Resize

    public func resize(columns newCols: Int, rows newRows: Int) {
        guard newCols >= 2, newRows >= 1, newCols != cols || newRows != rows else { return }

        // The main buffer reflows, so shrinking the window never loses text
        // and widening it joins wrapped lines back up. Full-screen apps on
        // the alternate screen redraw on SIGWINCH, so that one is clipped.
        if isAlternateScreen {
            var activeCursorRow = cursorRow
            resizeBuffer(
                &screen,
                newCols: newCols,
                newRows: newRows,
                pushToScrollback: false,
                cursorRow: &activeCursorRow
            )
            cursorRow = activeCursorRow
            if let saved = savedMainScreen {
                let cursor = (savedMainCursor?.row ?? 0, savedMainCursor?.col ?? 0)
                let result = reflow(saved, cursor: cursor, newCols: newCols, newRows: newRows)
                savedMainScreen = result.screen
                savedMainCursor?.row = result.cursor.row
                savedMainCursor?.col = min(result.cursor.col, newCols - 1)
            }
        } else {
            let result = reflow(screen, cursor: (cursorRow, cursorCol), newCols: newCols, newRows: newRows)
            screen = result.screen
            cursorRow = result.cursor.row
            cursorCol = result.cursor.col
        }

        cols = newCols
        rows = newRows
        scrollBottom = rows - 1
        scrollTop = min(scrollTop, rows - 1)
        if scrollTop >= scrollBottom {
            scrollTop = 0
            scrollBottom = rows - 1
        }
        cursorCol = min(cursorCol, cols - 1)
        cursorRow = min(cursorRow, rows - 1)
        pendingWrap = false
        pendingZWJCell = nil

        var stops = Array(repeating: false, count: cols)
        for index in 0..<min(cols, tabStops.count) {
            stops[index] = tabStops[index]
        }
        var column = 8
        while column < cols {
            if column >= tabStops.count {
                stops[column] = true
            }
            column += 8
        }
        tabStops = stops
        markDirty()
    }

    /// Re-wraps scrollback plus `screenLines` to `newCols`, then splits the
    /// result into a new screen of `newRows` and the scrollback above it.
    private func reflow(
        _ screenLines: [TermLine],
        cursor: (row: Int, col: Int),
        newCols: Int,
        newRows: Int
    ) -> (screen: [TermLine], cursor: (row: Int, col: Int)) {
        var source = scrollback
        source.append(contentsOf: screenLines)
        let cursorLine = scrollback.count + cursor.row

        // Blank rows below both the cursor and the last text are just unused
        // screen; drop them rather than pushing them into scrollback.
        var end = source.count - 1
        while end > cursorLine, source[end].cells.allSatisfy({ $0.isVisuallyBlank() }) {
            end -= 1
        }

        var output: [TermLine] = []
        output.reserveCapacity(end + 1)
        var newCursor = (line: 0, col: 0)
        var logical: [Cell] = []
        var cursorOffset: Int?

        var index = 0
        while index <= end {
            let line = source[index]
            if index == cursorLine {
                cursorOffset = logical.count + cursor.col
            }
            // Fast path: a lone line that already fits needs no re-wrapping,
            // which keeps resizing cheap with a long scrollback.
            if logical.isEmpty, !line.wrapped, index != cursorLine {
                let used = Self.usedWidth(line.cells)
                if used <= newCols {
                    output.append(Self.fitted(line, to: newCols, used: used))
                    index += 1
                    continue
                }
            }
            if line.wrapped {
                var cells = line.cells[...]
                // A wide character that didn't fit left a padding blank at
                // the end of the row; it isn't part of the text.
                if index < end, source[index + 1].cells.first?.width == 2,
                   let last = cells.last, last.isVisuallyBlank(), last.text == " " {
                    cells = cells.dropLast()
                }
                logical.append(contentsOf: cells)
            } else {
                logical.append(contentsOf: line.cells.prefix(Self.usedWidth(line.cells)))
                let start = output.count
                let placement = Self.wrap(logical, into: newCols, cursorOffset: cursorOffset, output: &output)
                if cursorOffset != nil, let placement {
                    newCursor = (start + placement.row, placement.col)
                }
                logical.removeAll(keepingCapacity: true)
                cursorOffset = nil
            }
            index += 1
        }
        if !logical.isEmpty || cursorOffset != nil {
            // The last line was still marked wrapped (the cursor sits after it).
            let start = output.count
            let placement = Self.wrap(logical, into: newCols, cursorOffset: cursorOffset, output: &output)
            if cursorOffset != nil, let placement {
                newCursor = (start + placement.row, placement.col)
            }
        }

        // Keep the screen pinned to the bottom, but never above the cursor.
        let top = min(max(0, output.count - newRows), newCursor.line)
        var newScreen = Array(output[top..<min(output.count, top + newRows)])
        while newScreen.count < newRows {
            newScreen.append(TermLine(columns: newCols))
        }
        if scrollbackLimit > 0 {
            scrollback = output[..<top].map { line in
                var copy = line
                copy.cells.removeLast(copy.cells.count - max(1, Self.usedWidth(copy.cells)))
                return copy
            }
            clearScrollbackIfNeeded()
        } else {
            scrollback = []
        }
        return (newScreen, (newCursor.line - top, min(newCursor.col, newCols - 1)))
    }

    /// Columns up to and including the last visible cell. The right half of
    /// a wide character counts as used even though it draws nothing.
    private static func usedWidth(_ cells: [Cell]) -> Int {
        var used = cells.count
        while used > 0, !cells[used - 1].isContinuation, cells[used - 1].isVisuallyBlank() {
            used -= 1
        }
        return used
    }

    private static func fitted(_ line: TermLine, to cols: Int, used: Int) -> TermLine {
        var copy = line
        if copy.cells.count > cols {
            copy.cells.removeLast(copy.cells.count - max(cols, used))
        } else if copy.cells.count < cols {
            copy.cells.append(contentsOf: repeatElement(Cell.blank, count: cols - copy.cells.count))
        }
        copy.wrapped = false
        return copy
    }

    /// Lays one logical line out in rows of `cols`, never splitting a wide
    /// character. Returns where `cursorOffset` (a cell index into `cells`,
    /// possibly past its end) lands.
    @discardableResult
    private static func wrap(_ cells: [Cell], into cols: Int, cursorOffset: Int?,
                             output: inout [TermLine]) -> (row: Int, col: Int)? {
        var rows: [[Cell]] = [[]]
        var placement: (row: Int, col: Int)?
        for (offset, cell) in cells.enumerated() {
            if !cell.isContinuation {
                let width = max(1, Int(cell.width))
                if rows[rows.count - 1].count + width > cols {
                    rows.append([])
                }
            }
            if offset == cursorOffset {
                placement = (rows.count - 1, rows[rows.count - 1].count)
            }
            rows[rows.count - 1].append(cell)
        }
        if let cursorOffset, placement == nil {
            // Past the text, e.g. after a prompt's trailing space.
            let lastRow = rows.count - 1
            let linear = lastRow * cols + rows[lastRow].count + (cursorOffset - cells.count)
            placement = (linear / cols, linear % cols)
            while rows.count <= placement!.row {
                rows.append([])
            }
        }
        for (index, row) in rows.enumerated() {
            var line = TermLine(cells: row, wrapped: index < rows.count - 1)
            if line.cells.count < cols {
                line.cells.append(contentsOf: repeatElement(Cell.blank, count: cols - line.cells.count))
            }
            output.append(line)
        }
        return placement
    }

    private func resizeBuffer(
        _ buffer: inout [TermLine],
        newCols: Int,
        newRows: Int,
        pushToScrollback: Bool,
        cursorRow cursor: inout Int
    ) {
        let oldRows = buffer.count
        if newCols != cols {
            for index in buffer.indices {
                var line = buffer[index]
                if newCols < line.cells.count {
                    line.cells.removeLast(line.cells.count - newCols)
                    if let last = line.cells.last, last.width == 2 {
                        line.cells[line.cells.count - 1] = blankCell(background: .default)
                    }
                } else if newCols > line.cells.count {
                    line.cells.append(contentsOf: Array(repeating: Cell.blank, count: newCols - line.cells.count))
                }
                line.wrapped = false
                buffer[index] = line
            }
        }

        if newRows < oldRows {
            let drop = oldRows - newRows
            if pushToScrollback {
                for index in 0..<min(drop, buffer.count) {
                    pushScrollback(buffer[index])
                }
            }
            buffer.removeFirst(min(drop, buffer.count))
            cursor = max(0, cursor - drop)
        } else if newRows > oldRows {
            let blanks = Array(repeating: TermLine(columns: newCols), count: newRows - oldRows)
            buffer.append(contentsOf: blanks)
        }
        if buffer.count > newRows {
            buffer.removeLast(buffer.count - newRows)
        }
        cursor = min(max(cursor, 0), max(0, newRows - 1))
    }

    // MARK: - Notification

    private func markDirty() {
        dirty = true
    }

    private func flush() {
        guard dirty else { return }
        dirty = false
        revision &+= 1
        onUpdate?()
    }

    private func reply(_ text: String) {
        onReply?(Data(text.utf8))
    }
}

// MARK: - Incremental UTF-8 decoding

private struct UTF8Decoder {
    private var bytes: [UInt8] = []
    private var expected = 0

    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        expected = 0
    }

    /// The decoded scalar, if one is complete. `retry` is set when `byte`
    /// interrupted a sequence: the caller shows U+FFFD and feeds `byte` again.
    mutating func feed(_ byte: UInt8) -> (Unicode.Scalar?, retry: Bool) {
        if expected == 0 {
            if byte < 0x80 {
                return (Unicode.Scalar(byte), false)
            }
            switch byte {
            case 0xC2...0xDF:
                expected = 2
            case 0xE0...0xEF:
                expected = 3
            case 0xF0...0xF4:
                expected = 4
            default:
                return (Unicode.Scalar(0xFFFD), false)
            }
            bytes = [byte]
            return (nil, false)
        }

        guard byte & 0xC0 == 0x80 else {
            reset()
            return (Unicode.Scalar(0xFFFD), true)
        }
        bytes.append(byte)
        if bytes.count < expected {
            return (nil, false)
        }

        let decoded = String(decoding: bytes, as: UTF8.self)
        bytes.removeAll(keepingCapacity: true)
        expected = 0
        guard let scalar = decoded.unicodeScalars.first, decoded.unicodeScalars.count == 1 else {
            return (Unicode.Scalar(0xFFFD), false)
        }
        return (scalar, false)
    }
}
