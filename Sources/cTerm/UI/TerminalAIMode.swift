import AppKit
import TerminalCore

/// AI mode, right in the terminal. The shell's prompt gives way to an
/// "✦ AI ›" line; what the user types there is echoed locally and never sent
/// to the shell. Replies print below it, and a suggested command waits on a
/// confirm line until Enter sends it to the shell.
///
/// Everything AI mode shows is fed straight into the local terminal screen,
/// so it scrolls and selects like any other output. Leaving the mode asks the
/// shell for a fresh prompt (Ctrl-U, Enter) below the transcript.
@MainActor
final class TerminalAIMode {
    private enum Phase {
        case input
        case waiting
        case confirm
    }

    /// Writes to the shell.
    var sendToShell: ((Data) -> Void)?
    var contextProvider: (() -> AITerminalContext)?
    var onExit: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    let conversation = AIConversation()
    private let terminal: Terminal
    private var theme: TerminalTheme
    private var phase: Phase = .input
    private var buffer = ""
    /// Absolute line where the current prompt or confirm line starts, so a
    /// redraw can step back over its wrapped rows.
    private var lineStart = 0
    private var commands: [String] = []
    private var selected = 0
    private var printedLines = 0
    private var fence: (language: String, runnable: Bool, first: Bool)?
    private var showingThinking = false
    /// Commands printed so far in this reply, for their numbers.
    private var numbered = 0
    /// No two blank gutter lines in a row, and none before the first text.
    private var lastWasBlank = true
    /// A blank gutter line waits for the next text, so none trails a reply.
    private var pendingBlank = false
    private var watchedTurn: UUID?

    init(terminal: Terminal, theme: TerminalTheme) {
        self.terminal = terminal
        self.theme = theme
        conversation.onChange = { [weak self] in self?.conversationChanged() }
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
    }

    // MARK: - Entering and leaving

    func begin() {
        phase = .input
        buffer = ""
        // Start on a line of our own, under whatever the shell left there.
        feed("\r\n")
        if conversation.turns.isEmpty {
            feed("  " + dim("AI 模式：直接输入问题，回车发送 · Esc 退出 · /new 开始新对话") + "\r\n")
        }
        drawPrompt()
    }

    /// Clears the AI line and lets the shell draw a fresh prompt.
    private func finish(running command: String? = nil, insertOnly: Bool = false) {
        // A reply still streaming must not print after the shell is back.
        watchedTurn = nil
        phase = .input
        conversation.cancel()
        clearThinking()
        eraseCurrentLine()
        var text = "\u{15}\r"
        if let command {
            var body = command
            if body.contains("\n") {
                body = terminal.bracketedPaste
                    ? "\u{1B}[200~" + body + "\u{1B}[201~"
                    : body.replacingOccurrences(of: "\n", with: "\r")
            }
            text += body + (insertOnly ? "" : "\r")
        }
        sendToShell?(Data(text.utf8))
        onExit?()
    }

    /// ⌘· again.
    func end() {
        finish()
    }

    /// The connection went away: stop without writing to the shell.
    func abandon() {
        watchedTurn = nil
        phase = .input
        conversation.cancel()
    }

    // MARK: - Keys

    /// Bytes the terminal view would have sent to the shell.
    func handle(_ data: Data) {
        guard var text = String(data: data, encoding: .utf8) else { return }
        text = text.replacingOccurrences(of: "\u{1B}[200~", with: "").replacingOccurrences(of: "\u{1B}[201~", with: "")
        if text == "\u{1B}" {
            escape()
            return
        }
        if text.hasPrefix("\u{1B}") {
            arrow(text)
            return
        }
        // More than one character at once is a paste or an IME commit.
        if text.count > 1 {
            let flat = text.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            type(flat.filter { !$0.isASCII || $0.asciiValue! >= 0x20 })
            return
        }
        switch text {
        case "\r", "\n": enter()
        case "\u{7F}", "\u{08}": backspace()
        case "\u{15}": clearInput()
        case "\u{03}": interrupt()
        case "\t": tab()
        default:
            if let scalar = text.unicodeScalars.first, scalar.value >= 0x20 { type(text) }
        }
    }

    private func type(_ text: String) {
        guard !text.isEmpty else { return }
        switch phase {
        case .waiting:
            return
        case .confirm:
            // Typing instead of confirming asks a follow-up question.
            eraseCurrentLine()
            phase = .input
            buffer = text
            drawPrompt()
        case .input:
            buffer += text
            redrawPrompt()
        }
    }

    private func backspace() {
        guard phase == .input, !buffer.isEmpty else { return }
        buffer.removeLast()
        redrawPrompt()
    }

    private func clearInput() {
        guard phase == .input, !buffer.isEmpty else { return }
        buffer = ""
        redrawPrompt()
    }

    private func enter() {
        switch phase {
        case .waiting:
            return
        case .confirm:
            finish(running: commands[selected])
        case .input:
            submit()
        }
    }

    private func tab() {
        guard phase == .confirm else { return }
        finish(running: commands[selected], insertOnly: true)
    }

    private func escape() {
        switch phase {
        case .waiting: interrupt()
        case .input, .confirm: finish()
        }
    }

    private func interrupt() {
        if phase == .waiting {
            conversation.cancel()
        } else {
            finish()
        }
    }

    private func arrow(_ sequence: String) {
        guard phase == .confirm, commands.count > 1 else { return }
        let up = sequence.hasSuffix("A")
        let down = sequence.hasSuffix("B")
        guard up || down else { return }
        selected = (selected + (down ? 1 : commands.count - 1)) % commands.count
        eraseCurrentLine()
        drawConfirm()
    }

    // MARK: - Asking

    private func submit() {
        let question = buffer.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        if question == "/new" || question == "/clear" {
            conversation.reset()
            buffer = ""
            feed("\r\n  " + dim("已开始新对话。") + "\r\n")
            drawPrompt()
            return
        }
        feed("\r\n")
        guard AISettings.isConfigured else {
            feed(gutter() + color(theme.palette[1]) + "还没有设置 AI 服务，请在“设置 → AI”中选择服务商并填写模型。" + reset + "\r\n")
            buffer = ""
            drawPrompt()
            onOpenSettings?()
            return
        }
        guard let context = contextProvider?() else { return }
        phase = .waiting
        buffer = ""
        printedLines = 0
        numbered = 0
        fence = nil
        pendingBlank = false
        lastWasBlank = false
        feed(gutter(blank: true) + "\r\n")
        lastWasBlank = true
        feed(gutter() + dim("思考中…"))
        showingThinking = true
        conversation.send(question, context: context)
        watchedTurn = conversation.turns.last?.id
    }

    private func conversationChanged() {
        guard phase == .waiting, let turn = conversation.turns.last, turn.id == watchedTurn else { return }
        let lines = turn.reply.components(separatedBy: "\n")
        let finished = turn.state != .streaming
        // While streaming, the last line may still grow; print it at the end.
        let ready = finished ? lines.count : lines.count - 1
        if ready > printedLines {
            clearThinking()
            for line in lines[printedLines..<ready] { printReplyLine(line) }
            printedLines = ready
        }
        guard finished else { return }
        clearThinking()
        switch turn.state {
        case .failed(let message):
            flushBlank()
            for line in wrap(runs([(message, color(theme.palette[1]))]), width: textWidth) {
                feed(gutter() + line + "\r\n")
            }
        case .cancelled:
            flushBlank()
            feed(gutter() + dim("已停止。") + "\r\n")
        default:
            break
        }
        pendingBlank = false
        feed(color(barColor) + "╰─" + reset + "\r\n")
        commands = AIReplySegment.parse(turn.reply).compactMap { segment in
            if case .code(let code, true, true) = segment, !code.isEmpty { return code }
            return nil
        }
        if turn.state == .done, !commands.isEmpty {
            phase = .confirm
            selected = 0
            drawConfirm()
        } else {
            phase = .input
            drawPrompt()
        }
    }

    // MARK: - Drawing

    private func drawPrompt() {
        lineStart = terminal.cursorLine
        feed(bold + color(theme.accent) + "✦ AI ›" + reset + " " + buffer)
    }

    /// Steps back to where the prompt began and draws it again, so editing
    /// works across wrapped rows and wide characters.
    private func redrawPrompt() {
        eraseCurrentLine()
        drawPrompt()
    }

    private func eraseCurrentLine() {
        let up = max(0, terminal.cursorLine - lineStart)
        feed("\r" + (up > 0 ? "\u{1B}[\(up)A" : "") + "\u{1B}[J")
    }

    /// Two rows: the chosen command on a bright chip, then the keys. Each
    /// is cut to the terminal width so the pair always takes exactly two rows.
    private func drawConfirm() {
        lineStart = terminal.cursorLine
        let command = commands[selected]
        let risky = AIReplySegment.looksDestructive(command)
        let label = "▶ 执行 \(selected + 1) › "
        let warning = risky ? "  ⚠ 请确认" : ""
        var shown = command.components(separatedBy: "\n").first ?? command
        if command.contains("\n") { shown += " …" }
        let budget = max(10, terminal.cols - CharWidth.width(label) - CharWidth.width(warning) - 4)
        if CharWidth.width(shown) > budget { shown = truncate(shown, to: budget - 1) + "…" }
        var line = bold + color(theme.accent) + label + reset
        line += chip(shown, number: nil, selected: true)
        if risky { line += color(theme.palette[3]) + warning + reset }
        var hints = "  ↩ 执行   ⇥ 放到命令行编辑"
        if commands.count > 1 { hints += "   ↑↓ 选择 \(selected + 1)/\(commands.count)" }
        hints += "   esc 退出   直接输入可继续追问"
        if CharWidth.width(hints) > terminal.cols - 1 { hints = truncate(hints, to: terminal.cols - 2) }
        feed(line + "\r\n" + dim(hints))
    }

    private func printReplyLine(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if fence == nil {
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                let runnable = ["", "bash", "sh", "shell", "zsh", "console", "fish"].contains(language)
                if runnable { numbered += 1 }
                blankLine()
                fence = (language, runnable, true)
            } else {
                fence = nil
                blankLine()
            }
            return
        }
        if var block = fence {
            flushBlank()
            if block.runnable {
                // Long commands are cut into chip rows here; what runs is the
                // original text.
                let pieces = hardWrap(raw, width: max(16, textWidth - 6))
                for (index, piece) in pieces.enumerated() {
                    let number = block.first && index == 0 ? numbered : nil
                    feed(gutter() + "  " + chip(piece, number: number, selected: false, indent: !(block.first && index == 0))
                         + "\r\n")
                }
            } else {
                for piece in hardWrap(raw, width: max(16, textWidth - 4)) {
                    feed(gutter() + "  " + dim(piece) + "\r\n")
                }
            }
            block.first = false
            fence = block
            lastWasBlank = false
            return
        }
        if trimmed.isEmpty {
            blankLine()
            return
        }
        flushBlank()
        for line in wrap(inlineRuns(raw), width: textWidth) {
            feed(gutter() + line + "\r\n")
        }
        lastWasBlank = false
    }

    private func blankLine() {
        guard !lastWasBlank else { return }
        pendingBlank = true
        lastWasBlank = true
    }

    private func flushBlank() {
        guard pendingBlank else { return }
        pendingBlank = false
        feed(gutter(blank: true) + "\r\n")
    }

    private func clearThinking() {
        guard showingThinking else { return }
        showingThinking = false
        feed("\r\u{1B}[2K")
    }

    // MARK: - Text layout

    /// Answers wrap at a readable width, not the full width of a wide window.
    private var textWidth: Int { max(20, min(terminal.cols, 96) - 3) }

    private func gutter(blank: Bool = false) -> String {
        color(barColor) + (blank ? "│" : "│ ") + reset
    }

    /// A command on a tinted chip: a number in front in the reply, brighter
    /// with a blue edge on the confirm line.
    private func chip(_ text: String, number: Int?, selected: Bool, indent: Bool = false) -> String {
        let fill = theme.background.blended(withFraction: selected ? 0.30 : 0.14, of: theme.accent) ?? theme.background
        let ink = theme.isDark ? NSColor.white : theme.foreground
        var out = background(fill)
        if selected {
            out += color(theme.accent) + "▎" + reset + background(fill)
        } else {
            out += " "
        }
        if let number {
            out += color(theme.accent) + "\(number)" + "  "
        } else if indent {
            out += "   "
        }
        out += bold + color(ink) + text + " " + reset
        return out
    }

    private typealias Run = (text: String, style: String)

    private func runs(_ parts: [(String, String)]) -> [Run] {
        parts.map { Run(text: $0.0, style: $0.1) }
    }

    /// Prose in a quiet grey; `code` a little brighter; ** markers dropped.
    private func inlineRuns(_ text: String) -> [Run] {
        let prose = color(proseColor)
        let code = color(inlineCodeColor)
        var result: [Run] = []
        var current = ""
        var inCode = false
        var index = text.startIndex
        func flush() {
            if !current.isEmpty { result.append(Run(text: current, style: inCode ? code : prose)) }
            current = ""
        }
        while index < text.endIndex {
            if text[index] == "`" {
                flush()
                inCode.toggle()
                index = text.index(after: index)
                continue
            }
            if !inCode, text[index...].hasPrefix("**") {
                index = text.index(index, offsetBy: 2)
                continue
            }
            current.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return result
    }

    /// Breaks styled text into rows of at most `width` cells, at a space
    /// when there is one late enough in the row, else anywhere (CJK).
    private func wrap(_ runs: [Run], width: Int) -> [String] {
        var cells: [(Character, String, Int)] = []
        for run in runs {
            for character in run.text { cells.append((character, run.style, CharWidth.width(String(character)))) }
        }
        var rows: [[(Character, String, Int)]] = []
        var row: [(Character, String, Int)] = []
        var used = 0
        for cell in cells {
            if used + cell.2 > width, !row.isEmpty {
                if let space = row.lastIndex(where: { $0.0 == " " }), space > row.count / 2 {
                    let rest = Array(row[(space + 1)...])
                    rows.append(Array(row[..<space]))
                    row = rest
                    used = rest.reduce(0) { $0 + $1.2 }
                } else {
                    rows.append(row)
                    row = []
                    used = 0
                }
                if cell.0 == " ", row.isEmpty { continue }
            }
            row.append(cell)
            used += cell.2
        }
        if !row.isEmpty { rows.append(row) }
        return rows.map { cells in
            var out = ""
            var style = ""
            for cell in cells {
                if cell.1 != style {
                    out += reset + cell.1
                    style = cell.1
                }
                out.append(cell.0)
            }
            return out + reset
        }
    }

    private func hardWrap(_ text: String, width: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while CharWidth.width(String(rest)) > width {
            let piece = truncate(String(rest), to: width)
            guard !piece.isEmpty else { break }
            pieces.append(piece)
            rest = rest.dropFirst(piece.count)
        }
        pieces.append(String(rest))
        return pieces
    }

    // MARK: - Output

    private func feed(_ text: String) {
        terminal.feed(text)
    }

    private let reset = "\u{1B}[0m"
    private let bold = "\u{1B}[1m"

    private var proseColor: NSColor {
        theme.foreground.blended(withFraction: theme.isDark ? 0.45 : 0.40, of: theme.background) ?? theme.subtle
    }

    private var inlineCodeColor: NSColor {
        theme.foreground.blended(withFraction: 0.25, of: theme.background) ?? theme.foreground
    }

    private var barColor: NSColor {
        theme.accent.blended(withFraction: theme.isDark ? 0.70 : 0.65, of: theme.background) ?? theme.subtle
    }

    private func dim(_ text: String) -> String {
        color(theme.subtle) + text + reset
    }

    private func color(_ color: NSColor) -> String {
        let (r, g, b) = components(color)
        return "\u{1B}[38;2;\(r);\(g);\(b)m"
    }

    private func background(_ color: NSColor) -> String {
        let (r, g, b) = components(color)
        return "\u{1B}[48;2;\(r);\(g);\(b)m"
    }

    private func components(_ color: NSColor) -> (Int, Int, Int) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return (Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()),
                Int((rgb.blueComponent * 255).rounded()))
    }

    private func truncate(_ text: String, to width: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let w = CharWidth.width(String(character))
            if used + w > width { break }
            result.append(character)
            used += w
        }
        return result
    }

    #if DEBUG
    var debugPhase: String { "\(phase)" }
    #endif
}
