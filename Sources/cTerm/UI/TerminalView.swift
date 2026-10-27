import AppKit
import CoreText
import TerminalCore

final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation {
    // MARK: - Configuration

    let terminal: Terminal
    var theme: TerminalTheme {
        didSet { needsDisplay = true }
    }

    var fontSize: CGFloat {
        didSet {
            guard fontSize != oldValue else { return }
            rebuildFonts()
            lineCache.removeAll(keepingCapacity: true)
            updateGridSize()
            needsDisplay = true
        }
    }

    var onSend: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var isInputEnabled = true {
        didSet { needsDisplay = true }
    }

    /// 0 lets the shared glass surface show through; 1 paints the theme background.
    var backgroundOpacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    // MARK: - Layout metrics

    private let paddingLeft: CGFloat = 16
    private let paddingRight: CGFloat = 16
    private let paddingTop: CGFloat = 12
    private let paddingBottom: CGFloat = 12

    private var regularFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
    private var italicFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldItalicFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 18
    private var baselineOffset: CGFloat = 13
    private var ascent: CGFloat = 10
    private var descent: CGFloat = 3

    var cols: Int { terminal.cols }
    var rows: Int { terminal.rows }

    // MARK: - Scrolling and selection

    private var scrollOffset = 0
    private var lastTotalLineCount = 0
    private var scrollRemainder: CGFloat = 0
    private var selectionAnchor: GridPoint?
    private var selectionFocus: GridPoint?
    private var mouseSelecting = false
    private var didDrag = false
    private var clickCount = 0

    private struct GridPoint: Equatable {
        var line: Int
        var col: Int
    }

    // MARK: - Cursor / IME

    private var blinkOn = true
    private var blinkTimer: Timer?
    private var keyObservers: [NSObjectProtocol] = []
    private var markedText: String = ""
    private var markedSelectedRange = NSRange(location: 0, length: 0)
    private var lineCache: [CTLineKey: CTLine] = [:]

    private struct CTLineKey: Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
        let color: UInt32
    }

    private struct FontStyleKey: Hashable {
        let bold: Bool
        let italic: Bool
    }

    // MARK: - Init

    init(terminal: Terminal, theme: TerminalTheme, fontSize: CGFloat) {
        self.terminal = terminal
        self.theme = theme
        self.fontSize = fontSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        rebuildFonts()
        lastTotalLineCount = terminal.totalLineCount
        terminal.onUpdate = { [weak self] in self?.terminalDidUpdate() }
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        blinkTimer?.invalidate()
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: - Fonts and geometry

    private func rebuildFonts() {
        regularFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let manager = NSFontManager.shared
        italicFont = manager.convert(regularFont, toHaveTrait: .italicFontMask)
        boldItalicFont = manager.convert(boldFont, toHaveTrait: .italicFontMask)

        let attributes: [NSAttributedString.Key: Any] = [.font: regularFont]
        let advance = ("M" as NSString).size(withAttributes: attributes).width
        // Use the exact advance: for a monospaced font this keeps every text
        // run aligned with the character grid, even at fractional point sizes.
        cellWidth = max(4, advance)

        ascent = regularFont.ascender
        descent = -regularFont.descender
        let leading = max(0, regularFont.leading)
        let lineBox = ascent + descent + leading
        cellHeight = max(8, ceil(lineBox) + 3)
        baselineOffset = (cellHeight - lineBox) / 2 + descent
    }

    private var usableWidth: CGFloat { max(1, bounds.width - paddingLeft - paddingRight) }
    private var usableHeight: CGFloat { max(1, bounds.height - paddingTop - paddingBottom) }
    private var computedCols: Int { max(2, Int(floor(usableWidth / cellWidth))) }
    private var computedRows: Int { max(1, Int(floor(usableHeight / cellHeight))) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
    }

    override func layout() {
        super.layout()
        updateGridSize()
    }

    private func updateGridSize() {
        guard bounds.width > 4, bounds.height > 4 else { return }
        let newCols = computedCols
        let newRows = computedRows
        guard newCols != terminal.cols || newRows != terminal.rows else {
            clampScrollOffset()
            return
        }
        terminal.resize(columns: newCols, rows: newRows)
        lastTotalLineCount = terminal.totalLineCount
        clampScrollOffset()
        onResize?(newCols, newRows)
        needsDisplay = true
    }

    func resetViewState() {
        scrollOffset = 0
        selectionAnchor = nil
        selectionFocus = nil
        markedText = ""
        lastTotalLineCount = terminal.totalLineCount
        needsDisplay = true
    }

    /// Called by the session when a connection is (re)established and the grid
    /// should be sized before the first bytes arrive.
    func prepareForConnection() {
        updateGridSize()
    }

    private var maxScrollOffset: Int {
        max(0, terminal.totalLineCount - terminal.rows)
    }

    private func clampScrollOffset() {
        if terminal.isAlternateScreen {
            scrollOffset = 0
        } else {
            scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
        }
    }

    private func firstVisibleLine() -> Int {
        let total = terminal.totalLineCount
        if total <= terminal.rows { return 0 }
        return max(0, total - terminal.rows - scrollOffset)
    }

    private func terminalDidUpdate() {
        let newTotal = terminal.totalLineCount
        if terminal.isAlternateScreen {
            scrollOffset = 0
            selectionAnchor = nil
            selectionFocus = nil
        } else if scrollOffset > 0 {
            let delta = newTotal - lastTotalLineCount
            if delta > 0 {
                scrollOffset = min(scrollOffset + delta, maxScrollOffset)
                if let anchor = selectionAnchor, let focus = selectionFocus {
                    selectionAnchor = GridPoint(line: anchor.line + delta, col: anchor.col)
                    selectionFocus = GridPoint(line: focus.line + delta, col: focus.col)
                }
            }
        }
        lastTotalLineCount = newTotal
        clampScrollOffset()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if backgroundOpacity > 0.001 {
            theme.background.withAlphaComponent(backgroundOpacity).setFill()
            bounds.fill()
        } else {
            // Clear to transparent so the shared glass surface remains visible
            // and stale glyphs do not accumulate between frames.
            context.clear(bounds)
        }
        context.saveGState()
        context.clip(to: bounds)

        let firstLine = firstVisibleLine()
        let total = terminal.totalLineCount
        let blinkSuppressed = !blinkOn && terminal.cursorBlink

        for viewRow in 0..<terminal.rows {
            let lineIndex = firstLine + viewRow
            guard lineIndex < total else { break }
            drawLine(lineIndex, viewRow: viewRow, context: context, blinkSuppressed: blinkSuppressed)
        }

        drawCursor(context: context, firstLine: firstLine)
        drawMarkedText(context: context, firstLine: firstLine)
        drawScrollIndicator(context: context)
        context.restoreGState()
    }

    private func rowRect(viewRow: Int) -> NSRect {
        let top = bounds.height - paddingTop - CGFloat(viewRow) * cellHeight
        return NSRect(
            x: paddingLeft,
            y: top - cellHeight,
            width: CGFloat(terminal.cols) * cellWidth,
            height: cellHeight
        )
    }

    private func baseline(forViewRow viewRow: Int) -> CGFloat {
        rowRect(viewRow: viewRow).minY + baselineOffset
    }

    private func drawLine(_ lineIndex: Int, viewRow: Int, context: CGContext, blinkSuppressed: Bool) {
        guard let line = terminal.line(at: lineIndex) else { return }
        let rect = rowRect(viewRow: viewRow)
        let selected = selectionColumns(forLine: lineIndex)

        // Backgrounds (including selection) are drawn first, cell by cell but
        // merged into runs where possible.
        var runStart = -1
        var runColor: NSColor?

        func flushBackground(endColumn: Int) {
            guard runStart >= 0, let color = runColor else { return }
            let x = rect.minX + CGFloat(runStart) * cellWidth
            let width = CGFloat(endColumn - runStart) * cellWidth
            context.setFillColor(color.cgColor)
            context.fill(NSRect(x: x, y: rect.minY, width: width, height: rect.height))
            runStart = -1
            runColor = nil
        }

        for column in 0..<terminal.cols {
            let cell = column < line.cells.count ? line.cells[column] : Cell.blank
            let isSelected = selected?.contains(column) ?? false
            let background = resolvedBackground(for: cell, selected: isSelected)
            if let background {
                if runStart == -1 {
                    runStart = column
                    runColor = background
                } else if runColor != background {
                    flushBackground(endColumn: column)
                    runStart = column
                    runColor = background
                }
            } else {
                flushBackground(endColumn: column)
            }
        }
        flushBackground(endColumn: terminal.cols)

        // Text runs.
        var column = 0
        while column < terminal.cols {
            let cell = column < line.cells.count ? line.cells[column] : Cell.blank
            if cell.isContinuation || cell.text.isEmpty || cell.text == " " || cell.attributes.contains(.hidden) {
                column += 1
                continue
            }
            if cell.width > 1 || CharWidth.width(cell.text) != 1 {
                if !blinkSuppressed || !cell.attributes.contains(.blink) {
                    drawCellText(
                        cell,
                        column: column,
                        viewRow: viewRow,
                        context: context,
                        selected: selected?.contains(column) ?? false
                    )
                }
                column += max(1, Int(cell.width))
                continue
            }

            let key = fontKey(for: cell)
            var text = cell.text
            var end = column + 1
            while end < terminal.cols {
                let next = end < line.cells.count ? line.cells[end] : Cell.blank
                guard !next.isContinuation, next.text != " ", !next.text.isEmpty,
                      !next.attributes.contains(.hidden),
                      next.width == 1,
                      CharWidth.width(next.text) == 1,
                      next.fg == cell.fg,
                      next.attributes.intersection([.dim, .inverse]) == cell.attributes.intersection([.dim, .inverse]),
                      (selected?.contains(end) ?? false) == (selected?.contains(column) ?? false),
                      fontKey(for: next) == key else { break }
                text += next.text
                end += 1
            }
            if blinkSuppressed && cell.attributes.contains(.blink) {
                column = end
                continue
            }
            let font = font(for: cell)
            let color = resolvedForeground(for: cell, selected: selected?.contains(column) ?? false)
            drawText(text, font: font, color: color, x: rect.minX + CGFloat(column) * cellWidth,
                     baseline: baseline(forViewRow: viewRow), context: context)

            let runBaseline = baseline(forViewRow: viewRow)
            for c in column..<end {
                let current = c < line.cells.count ? line.cells[c] : Cell.blank
                drawDecorations(cell: current, column: c, rect: rect, context: context,
                                color: resolvedForeground(for: current, selected: selected?.contains(c) ?? false),
                                baseline: runBaseline)
            }
            column = end
        }
    }

    private func drawCellText(_ cell: Cell, column: Int, viewRow: Int, context: CGContext, selected: Bool) {
        let font = font(for: cell)
        let color = resolvedForeground(for: cell, selected: selected)
        let baseline = baseline(forViewRow: viewRow)
        drawText(cell.text, font: font, color: color,
                 x: paddingLeft + CGFloat(column) * cellWidth,
                 baseline: baseline, context: context)
        drawDecorations(cell: cell, column: column, rect: rowRect(viewRow: viewRow), context: context,
                        color: color, baseline: baseline)
    }

    private func font(for cell: Cell) -> NSFont {
        let bold = cell.attributes.contains(.bold)
        let italic = cell.attributes.contains(.italic)
        switch (bold, italic) {
        case (true, true): return boldItalicFont
        case (true, false): return boldFont
        case (false, true): return italicFont
        case (false, false): return regularFont
        }
    }

    private func fontKey(for cell: Cell) -> FontStyleKey {
        FontStyleKey(
            bold: cell.attributes.contains(.bold),
            italic: cell.attributes.contains(.italic)
        )
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, x: CGFloat,
                          baseline: CGFloat, context: CGContext) {
        let line = cachedLine(text: text, font: font, color: color)
        context.saveGState()
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func cachedLine(text: String, font: NSFont, color: NSColor) -> CTLine {
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
        let italic = font.fontDescriptor.symbolicTraits.contains(.italic)
        let key = CTLineKey(text: text, bold: bold, italic: italic, color: colorKey(color))
        if let cached = lineCache[key] { return cached }
        if lineCache.count > 4000 { lineCache.removeAll(keepingCapacity: true) }
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        lineCache[key] = line
        return line
    }

    private func colorKey(_ color: NSColor) -> UInt32 {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        let r = UInt32((srgb.redComponent * 255).rounded())
        let g = UInt32((srgb.greenComponent * 255).rounded())
        let b = UInt32((srgb.blueComponent * 255).rounded())
        let a = UInt32((srgb.alphaComponent * 255).rounded())
        return (r << 24) | (g << 16) | (b << 8) | a
    }

    private func drawDecorations(cell: Cell, column: Int, rect: NSRect, context: CGContext,
                                 color: NSColor, baseline: CGFloat) {
        guard cell.attributes.contains(.underline) || cell.attributes.contains(.strikethrough) else { return }
        let x = paddingLeft + CGFloat(column) * cellWidth
        context.setFillColor(color.cgColor)
        if cell.attributes.contains(.underline) {
            let underlineY = baseline - 1.5
            context.fill(NSRect(x: x, y: underlineY, width: cellWidth, height: 1))
            if cell.attributes.contains(.doubleUnderline) {
                context.fill(NSRect(x: x, y: underlineY - 2, width: cellWidth, height: 1))
            }
        }
        if cell.attributes.contains(.strikethrough) {
            let strikeY = baseline + ascent * 0.28
            context.fill(NSRect(x: x, y: strikeY, width: cellWidth, height: 1))
        }
    }

    private func resolvedForeground(for cell: Cell, selected: Bool) -> NSColor {
        var color: NSColor
        switch cell.fg {
        case .default:
            color = theme.foreground
        case .indexed(let index):
            var effective = index
            if cell.attributes.contains(.bold), theme.boldUsesBright, index < 8 {
                effective = index + 8
            }
            color = theme.ansiColor(effective, override: terminal.resolvedPaletteOverride(effective))
        case .rgb(let rgb):
            color = theme.ansiColor(0, override: rgb)
        }
        if cell.attributes.contains(.inverse) {
            color = resolvedBackgroundColor(for: cell.bg, default: theme.background)
        }
        if selected, cell.bg == .default {
            color = theme.foreground
        }
        if cell.attributes.contains(.dim) {
            color = color.withAlphaComponent(0.62)
        }
        return color
    }

    private func resolvedBackground(for cell: Cell, selected: Bool) -> NSColor? {
        if selected { return theme.selection }
        if cell.attributes.contains(.inverse) {
            return resolvedBackgroundColor(for: cell.fg, default: theme.foreground)
        }
        if cell.bg == .default { return nil }
        return resolvedBackgroundColor(for: cell.bg, default: theme.background)
    }

    private func resolvedBackgroundColor(for color: TermColor, default fallback: NSColor) -> NSColor {
        switch color {
        case .default:
            return fallback
        case .indexed(let index):
            return theme.ansiColor(index, override: terminal.resolvedPaletteOverride(index))
        case .rgb(let rgb):
            return theme.ansiColor(0, override: rgb)
        }
    }

    private func drawCursor(context: CGContext, firstLine: Int) {
        guard isInputEnabled, terminal.cursorVisible, window?.isKeyWindow == true,
              window?.firstResponder === self else { return }
        if terminal.cursorBlink && !blinkOn && markedText.isEmpty { return }
        let cursorLine = terminal.cursorLine
        let viewRow = cursorLine - firstLine
        guard viewRow >= 0, viewRow < terminal.rows else { return }
        let rect = rowRect(viewRow: viewRow)
        let x = paddingLeft + CGFloat(terminal.cursorCol) * cellWidth
        let y = rect.minY
        let cell = terminal.cell(line: cursorLine, column: terminal.cursorCol)
        let cursorRect = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)

        switch terminal.cursorStyle {
        case .block:
            context.setFillColor(theme.cursor.withAlphaComponent(0.85).cgColor)
            context.fill(cursorRect)
            if !cell.text.isEmpty, cell.text != " ", !cell.isContinuation {
                context.setFillColor(theme.background.withAlphaComponent(0.95).cgColor)
                let line = cachedLine(text: cell.text, font: font(for: cell), color: theme.background)
                context.textPosition = CGPoint(x: x, y: rect.minY + baselineOffset)
                CTLineDraw(line, context)
            }
        case .bar:
            context.setFillColor(theme.cursor.cgColor)
            context.fill(NSRect(x: x, y: y + 1, width: 2, height: cellHeight - 2))
        case .underline:
            context.setFillColor(theme.cursor.cgColor)
            context.fill(NSRect(x: x, y: y + 1, width: cellWidth, height: 2))
        }
    }

    private func drawMarkedText(context: CGContext, firstLine: Int) {
        guard !markedText.isEmpty else { return }
        let cursorLine = terminal.cursorLine
        let viewRow = cursorLine - firstLine
        guard viewRow >= 0, viewRow < terminal.rows else { return }
        let rect = rowRect(viewRow: viewRow)
        let x = paddingLeft + CGFloat(terminal.cursorCol) * cellWidth
        let attributed = NSAttributedString(string: markedText, attributes: [.font: regularFont])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let background = NSRect(x: x, y: rect.minY + 1, width: max(cellWidth, width + 4), height: cellHeight - 2)
        context.setFillColor(theme.selection.cgColor)
        context.fill(background)
        context.setFillColor(theme.foreground.cgColor)
        context.textPosition = CGPoint(x: x + 2, y: rect.minY + baselineOffset)
        CTLineDraw(line, context)
        context.setFillColor(theme.accent.cgColor)
        context.fill(NSRect(x: x + 2, y: rect.minY + 2, width: max(cellWidth, width), height: 1.5))
    }

    private func drawScrollIndicator(context: CGContext) {
        let total = terminal.totalLineCount
        guard total > terminal.rows else { return }
        let trackHeight = max(20, bounds.height - paddingTop - paddingBottom - 12)
        let thumbHeight = max(24, trackHeight * CGFloat(terminal.rows) / CGFloat(total))
        let maxOffset = max(1, total - terminal.rows)
        // scrollOffset counts lines up from the newest output, so 0 (following
        // the output) puts the thumb at the bottom of the track.
        let progress = 1 - CGFloat(scrollOffset) / CGFloat(maxOffset)
        let top = bounds.height - paddingTop - 6 - progress * (trackHeight - thumbHeight)
        let rect = NSRect(x: bounds.width - 7, y: top - thumbHeight, width: 3, height: thumbHeight)
        let color = theme.subtle.withAlphaComponent(scrollOffset > 0 ? 0.7 : 0.28)
        context.setFillColor(color.cgColor)
        let path = CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        context.addPath(path)
        context.fillPath()
    }

    // MARK: - Selection

    private func normalizedSelection() -> (start: GridPoint, end: GridPoint)? {
        guard let anchor = selectionAnchor, let focus = selectionFocus else { return nil }
        if anchor.line < focus.line || (anchor.line == focus.line && anchor.col <= focus.col) {
            return (anchor, focus)
        }
        return (focus, anchor)
    }

    private func selectionColumns(forLine line: Int) -> ClosedRange<Int>? {
        guard let selection = normalizedSelection() else { return nil }
        guard line >= selection.start.line, line <= selection.end.line else { return nil }
        let start = line == selection.start.line ? selection.start.col : 0
        let end = line == selection.end.line ? selection.end.col : terminal.cols - 1
        guard start <= end else { return nil }
        return start...end
    }

    private func selectedText() -> String? {
        guard let selection = normalizedSelection() else { return nil }
        let total = terminal.totalLineCount
        guard total > 0 else { return nil }
        let startLine = min(max(0, selection.start.line), total - 1)
        let endLine = min(max(0, selection.end.line), total - 1)
        guard startLine <= endLine else { return nil }
        var result = ""
        for line in startLine...endLine {
            let start = line == selection.start.line ? max(0, selection.start.col) : 0
            let end = line == selection.end.line ? min(terminal.cols - 1, selection.end.col) : terminal.cols - 1
            var text = ""
            if start <= end {
                for column in start...end {
                    let cell = terminal.cell(line: line, column: column)
                    if cell.isContinuation { continue }
                    text += cell.text
                }
            }
            while text.hasSuffix(" ") { text.removeLast() }
            result += text
            if line != endLine, !terminal.isWrapped(line: line) {
                result += "\n"
            }
        }
        return result.isEmpty ? nil : result
    }

    @objc func copy(_ sender: Any?) {
        if let text = selectedText() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        } else if isInputEnabled {
            send(bytes: [0x03])
        }
    }

    @objc func paste(_ sender: Any?) {
        guard isInputEnabled else { return }
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return }
        var text = raw.replacingOccurrences(of: "\r\n", with: "\r")
        text = text.replacingOccurrences(of: "\n", with: "\r")
        if terminal.bracketedPaste {
            text = "\u{1B}[200~" + text + "\u{1B}[201~"
        }
        send(text: text)
    }

    override func selectAll(_ sender: Any?) {
        let total = terminal.totalLineCount
        guard total > 0 else { return }
        selectionAnchor = GridPoint(line: 0, col: 0)
        selectionFocus = GridPoint(line: total - 1, col: terminal.cols - 1)
        needsDisplay = true
    }

    /// For when a program (vim killed mid-session, say) left the cursor hidden
    /// or the terminal in an odd mode. Keeps the text and scrollback.
    @objc func resetTerminal(_ sender: Any?) {
        terminal.resetModes()
        scrollOffset = 0
        lastTotalLineCount = terminal.totalLineCount
        clearSelection()
        resetBlink()
        needsDisplay = true
    }

    @objc func clearBuffer(_ sender: Any?) {
        terminal.clearBuffer()
        scrollOffset = 0
        selectionAnchor = nil
        selectionFocus = nil
        lastTotalLineCount = terminal.totalLineCount
        needsDisplay = true
    }

    @objc func copySelectionOrInterrupt() {
        copy(nil)
    }

    private func clearSelection() {
        selectionAnchor = nil
        selectionFocus = nil
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let gridPoint = gridPoint(for: point) else { return }
        mouseSelecting = true
        didDrag = false
        clickCount = event.clickCount

        if event.modifierFlags.contains(.shift), selectionAnchor != nil {
            selectionFocus = gridPoint
        } else {
            selectionAnchor = gridPoint
            selectionFocus = gridPoint
        }

        if event.clickCount == 2 {
            selectWord(at: gridPoint)
            mouseSelecting = false
        } else if event.clickCount >= 3 {
            selectLogicalLine(at: gridPoint)
            mouseSelecting = false
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseSelecting else { return }
        didDrag = true
        var point = convert(event.locationInWindow, from: nil)
        let rowHeight = cellHeight
        let topLimit = bounds.height - paddingTop
        let bottomLimit = paddingBottom
        if point.y > topLimit {
            if scrollOffset < maxScrollOffset { scrollOffset += 1 }
            point.y = min(topLimit - 1, point.y)
        } else if point.y < bottomLimit {
            if scrollOffset > 0 { scrollOffset -= 1 }
            point.y = max(bottomLimit + 1, point.y)
        }
        if let gridPoint = gridPoint(for: point, clamp: true) {
            selectionFocus = gridPoint
        }
        _ = rowHeight
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mouseSelecting, !didDrag, clickCount == 1 {
            clearSelection()
        }
        mouseSelecting = false
        _ = selectedText()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "粘贴", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "清空屏幕", action: #selector(clearBuffer(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "重置终端", action: #selector(resetTerminal(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    private func gridPoint(for point: NSPoint, clamp: Bool = false) -> GridPoint? {
        let first = firstVisibleLine()
        var col = Int(floor((point.x - paddingLeft) / cellWidth))
        var row = Int(floor((bounds.height - paddingTop - point.y) / cellHeight))
        if !clamp {
            guard col >= 0, col < terminal.cols, row >= 0, row < terminal.rows else { return nil }
        }
        col = min(max(0, col), terminal.cols - 1)
        row = min(max(0, row), terminal.rows - 1)
        return GridPoint(line: first + row, col: col)
    }

    private func isWordCharacter(_ cell: Cell) -> Bool {
        guard let scalar = cell.text.unicodeScalars.first else { return false }
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return "_-./~:@".unicodeScalars.contains(scalar)
    }

    private func selectWord(at point: GridPoint) {
        var start = point.col
        var end = point.col
        while start > 0, isWordCharacter(terminal.cell(line: point.line, column: start - 1)) { start -= 1 }
        while end < terminal.cols - 1, isWordCharacter(terminal.cell(line: point.line, column: end + 1)) { end += 1 }
        selectionAnchor = GridPoint(line: point.line, col: start)
        selectionFocus = GridPoint(line: point.line, col: end)
    }

    private func selectLogicalLine(at point: GridPoint) {
        var startLine = point.line
        var endLine = point.line
        while startLine > 0, terminal.isWrapped(line: startLine - 1) { startLine -= 1 }
        while endLine < terminal.totalLineCount - 1, terminal.isWrapped(line: endLine) { endLine += 1 }
        selectionAnchor = GridPoint(line: startLine, col: 0)
        selectionFocus = GridPoint(line: endLine, col: terminal.cols - 1)
    }

    // MARK: - Scrolling

    override func scrollWheel(with event: NSEvent) {
        if terminal.isAlternateScreen, terminal.alternateScroll {
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.1 else { return }
            let upward = delta > 0
            let count = max(1, min(5, Int(abs(delta) / 10) + 1))
            let sequence = upward ? "\u{1B}[A" : "\u{1B}[B"
            for _ in 0..<count { send(text: sequence) }
            return
        }
        let delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += delta / cellHeight
        } else {
            scrollRemainder += delta
        }
        let lines = Int(scrollRemainder)
        if lines != 0 {
            scrollRemainder -= CGFloat(lines)
            let newOffset = min(max(0, scrollOffset + lines), maxScrollOffset)
            if newOffset != scrollOffset {
                scrollOffset = newOffset
                needsDisplay = true
            }
        }
    }

    func scrollToTop() {
        scrollOffset = maxScrollOffset
        needsDisplay = true
    }

    func scrollToBottom() {
        scrollOffset = 0
        needsDisplay = true
    }

    func pageUp() {
        scrollOffset = min(maxScrollOffset, scrollOffset + max(1, terminal.rows - 2))
        needsDisplay = true
    }

    func pageDown() {
        scrollOffset = max(0, scrollOffset - max(1, terminal.rows - 2))
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard isInputEnabled else {
            NSSound.beep()
            return
        }
        resetBlink()

        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)
        let control = modifiers.contains(.control)
        let command = modifiers.contains(.command)

        if command {
            switch event.keyCode {
            case 123: send(text: homeSequence()) // Cmd+Left
            case 124: send(text: endSequence()) // Cmd+Right
            case 126: scrollToTop()
            case 125: scrollToBottom()
            case 51: send(bytes: [0x15])
            default: break
            }
            return
        }

        if control {
            switch event.keyCode {
            case 51:
                send(bytes: [0x08])
                return
            case 48:
                send(text: "\t")
                return
            default:
                if let text = event.charactersIgnoringModifiers?.lowercased(),
                   let scalar = text.unicodeScalars.first {
                    if let controlByte = controlByte(for: scalar) {
                        send(bytes: [controlByte])
                        return
                    }
                }
            }
        }

        if let sequence = specialKeySequence(for: event, shift: shift, control: control, option: option) {
            if sequence == "__page_up__" {
                pageUp()
            } else if sequence == "__page_down__" {
                pageDown()
            } else if shift, event.keyCode == 116 || event.keyCode == 121 {
                // handled above
            } else {
                send(text: sequence)
            }
            return
        }

        if option, let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            send(text: "\u{1B}" + characters)
            return
        }

        interpretKeyEvents([event])
    }

    private func specialKeySequence(for event: NSEvent, shift: Bool, control: Bool, option: Bool) -> String? {
        let modifier = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)
        func cursor(_ final: String, appSS3: Bool = true) -> String {
            if modifier > 1 { return "\u{1B}[1;\(modifier)\(final)" }
            if appSS3, terminal.applicationCursorKeys { return "\u{1B}O\(final)" }
            return "\u{1B}[\(final)"
        }
        func tilde(_ number: Int) -> String {
            modifier > 1 ? "\u{1B}[\(number);\(modifier)~" : "\u{1B}[\(number)~"
        }
        func functionKey(_ final: String) -> String {
            modifier > 1 ? "\u{1B}[1;\(modifier)\(final)" : "\u{1B}O\(final)"
        }

        switch event.keyCode {
        case 36, 76: return "\r"
        case 48: return shift ? "\u{1B}[Z" : "\t"
        case 51: return option ? "\u{1B}\u{7F}" : "\u{7F}"
        case 53: return "\u{1B}"
        case 117: return tilde(3)
        case 114: return tilde(2)
        case 115:
            if modifier > 1 { return "\u{1B}[1;\(modifier)H" }
            return "\u{1B}[H"
        case 119:
            if modifier > 1 { return "\u{1B}[1;\(modifier)F" }
            return "\u{1B}[F"
        case 116:
            if shift && modifier == 2 { return "__page_up__" }
            return tilde(5)
        case 121:
            if shift && modifier == 2 { return "__page_down__" }
            return tilde(6)
        case 123: return cursor("D")
        case 124: return cursor("C")
        case 125: return cursor("B")
        case 126: return cursor("A")
        case 122: return functionKey("P")
        case 120: return functionKey("Q")
        case 99: return functionKey("R")
        case 118: return functionKey("S")
        case 96: return tilde(15)
        case 97: return tilde(17)
        case 98: return tilde(18)
        case 100: return tilde(19)
        case 101: return tilde(20)
        case 109: return tilde(21)
        case 103: return tilde(23)
        case 111: return tilde(24)
        default: return nil
        }
    }

    private func homeSequence() -> String {
        terminal.applicationCursorKeys ? "\u{1B}OH" : "\u{1B}[H"
    }

    private func endSequence() -> String {
        terminal.applicationCursorKeys ? "\u{1B}OF" : "\u{1B}[F"
    }

    private func controlByte(for scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "a"..."z":
            return UInt8(scalar.value - 96)
        case " ":
            return 0x00
        case "[":
            return 0x1B
        case "\\":
            return 0x1C
        case "]":
            return 0x1D
        case "^":
            return 0x1E
        case "_":
            return 0x1F
        case "?":
            return 0x7F
        default:
            return nil
        }
    }

    private func send(text: String) {
        send(bytes: Array(text.utf8))
    }

    private func send(bytes: [UInt8]) {
        guard isInputEnabled else { return }
        scrollOffset = 0
        clearSelection()
        resetBlink()
        onSend?(Data(bytes))
    }

    override func doCommand(by selector: Selector) {
        switch NSStringFromSelector(selector) {
        case "insertNewline:", "insertParagraphSeparator:":
            send(text: "\r")
        case "insertTab:":
            send(text: "\t")
        case "insertBacktab:":
            send(text: "\u{1B}[Z")
        case "deleteBackward:":
            send(bytes: [0x7F])
        case "deleteForward:":
            send(text: "\u{1B}[3~")
        case "cancelOperation:":
            send(text: "\u{1B}")
        case "moveLeft:":
            send(text: cursorSequence("D"))
        case "moveRight:":
            send(text: cursorSequence("C"))
        case "moveUp:":
            send(text: cursorSequence("A"))
        case "moveDown:":
            send(text: cursorSequence("B"))
        case "moveToBeginningOfLine:", "scrollToBeginningOfDocument:":
            send(text: homeSequence())
        case "moveToEndOfLine:", "scrollToEndOfDocument:":
            send(text: endSequence())
        default:
            NSSound.beep()
        }
    }

    private func cursorSequence(_ final: String) -> String {
        terminal.applicationCursorKeys ? "\u{1B}O\(final)" : "\u{1B}[\(final)"
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            if terminal.focusReporting { onSend?(Data("\u{1B}[I".utf8)) }
            resetBlink()
            needsDisplay = true
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            if terminal.focusReporting { onSend?(Data("\u{1B}[O".utf8)) }
            needsDisplay = true
        }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers.removeAll()
        if let window {
            startBlinkTimer()
            let center = NotificationCenter.default
            keyObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.startBlinkTimer()
                self?.needsDisplay = true
            })
            keyObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            })
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        blinkOn = true
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.window?.isKeyWindow == true, self.window?.firstResponder === self else { return }
            self.blinkOn.toggle()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func resetBlink() {
        blinkOn = true
        needsDisplay = true
    }

    // MARK: - NSTextInputClient (IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard isInputEnabled else { return }
        markedText = ""
        let text: String
        if let value = string as? String {
            text = value
        } else if let value = string as? NSAttributedString {
            text = value.string
        } else {
            return
        }
        guard !text.isEmpty else { return }
        send(text: text)
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let value = string as? String {
            text = value
        } else if let value = string as? NSAttributedString {
            text = value.string
        } else {
            return
        }
        markedText = text
        markedSelectedRange = selectedRange
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        if markedText.isEmpty {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let firstLine = firstVisibleLine()
        let viewRow = terminal.cursorLine - firstLine
        let row = rowRect(viewRow: max(0, min(terminal.rows - 1, viewRow)))
        let x = paddingLeft + CGFloat(terminal.cursorCol) * cellWidth
        let rect = NSRect(x: x, y: row.minY, width: cellWidth, height: cellHeight)
        let inWindow = convert(rect, to: nil)
        return window.convertToScreen(inWindow)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isInputEnabled else { return false }
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        let paths = urls.map { shellEscape($0.path) }.joined(separator: " ") + " "
        send(text: paths)
        return true
    }

    private func shellEscape(_ path: String) -> String {
        if path.range(of: "^[A-Za-z0-9_./~-]+$", options: .regularExpression) != nil {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return selectedText() != nil || isInputEnabled
        case #selector(paste(_:)):
            return isInputEnabled && NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)):
            return terminal.totalLineCount > 0
        case #selector(clearBuffer(_:)):
            return true
        default:
            return true
        }
    }
}
