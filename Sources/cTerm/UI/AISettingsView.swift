import AppKit

/// The AI tab of Settings: an OpenAI-compatible service (address, key and
/// model) and how much terminal output goes with each question.
@MainActor
final class AISettingsView: NSView {
    private var theme: TerminalTheme
    private let titleLabel: NSTextField
    private let statusLabel: NSTextField
    private let explainLabel: NSTextField
    private let providerPopup = HandPopUpButton()
    private let baseURLField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyStateLabel: NSTextField
    private let saveKeyButton: NSButton
    private let removeKeyButton: NSButton
    private let modelField = NSTextField()
    private let contextPopup = HandPopUpButton()
    private let testButton: NSButton
    private let testSpinner = NSProgressIndicator()
    private let testLabel: NSTextField
    private let privacyLabel: NSTextField
    private var fieldLabels: [NSTextField] = []
    private var testTask: Task<Void, Never>?

    private static let contextChoices = [60, 120, 300, 600]
    private static let customTitle = "自定义"

    init(theme: TerminalTheme) {
        self.theme = theme
        titleLabel = UIFactory.label("AI 助手 · OpenAI 兼容接口", size: 13, weight: .semibold, color: theme.foreground)
        statusLabel = UIFactory.label("", size: 11, weight: .medium, color: theme.subtle, alignment: .right)
        explainLabel = UIFactory.wrappingLabel(
            "在终端里按 ⌘·（⌘`）进入 AI 模式：命令行变成“✦ AI ›”，直接用中文描述想做的事，AI 会结合终端最近的输出和当前目录给出命令。命令不会自动执行，按回车确认后才发送到终端；Esc 退出。支持 OpenAI、DeepSeek、通义千问、Kimi、智谱、Ollama 等兼容 OpenAI 接口的服务。",
            size: 11, color: theme.subtle
        )
        keyStateLabel = UIFactory.label("", size: 11, weight: .regular, color: theme.subtle)
        saveKeyButton = UIFactory.button("保存", target: nil, action: nil)
        removeKeyButton = UIFactory.button("删除", target: nil, action: nil)
        testButton = UIFactory.button("测试连接", target: nil, action: nil)
        testLabel = UIFactory.wrappingLabel("", size: 11, color: theme.subtle)
        privacyLabel = UIFactory.wrappingLabel("", size: 11, color: theme.subtle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .ctermAISettingsDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = UIFactory.label(text, size: 12, weight: .medium, color: theme.subtle)
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        fieldLabels.append(label)
        return label
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func style(_ field: NSTextField, placeholder: String) {
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
    }

    private func build() {
        let header = row([titleLabel, NSView(), statusLabel])

        providerPopup.addItems(withTitles: AIProviderPreset.all.map(\.name) + [Self.customTitle])
        providerPopup.target = self
        providerPopup.action = #selector(providerChosen(_:))
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        let providerRow = row([fieldLabel("服务商"), providerPopup, NSView()])

        style(baseURLField, placeholder: "https://api.example.com/v1")
        baseURLField.action = #selector(baseURLEdited(_:))
        baseURLField.delegate = self
        let urlRow = row([fieldLabel("API 地址"), baseURLField])

        style(keyField, placeholder: "sk-…")
        keyField.action = #selector(saveKey(_:))
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveKey(_:))
        saveKeyButton.controlSize = .regular
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeKey(_:))
        removeKeyButton.controlSize = .regular
        let keyRow = row([fieldLabel("API Key"), keyField, saveKeyButton, removeKeyButton])
        keyStateLabel.lineBreakMode = .byTruncatingTail
        let keyStateRow = row([NSView(), keyStateLabel])
        keyStateRow.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 72).isActive = true

        style(modelField, placeholder: "模型名称")
        modelField.action = #selector(modelEdited(_:))
        modelField.delegate = self
        let modelRow = row([fieldLabel("模型"), modelField])

        contextPopup.addItems(withTitles: Self.contextChoices.map { "最近 \($0) 行" })
        contextPopup.target = self
        contextPopup.action = #selector(contextChosen(_:))
        contextPopup.translatesAutoresizingMaskIntoConstraints = false
        let contextRow = row([fieldLabel("终端上下文"), contextPopup, NSView()])

        testButton.target = self
        testButton.action = #selector(test(_:))
        testButton.controlSize = .regular
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isDisplayedWhenStopped = false
        testSpinner.translatesAutoresizingMaskIntoConstraints = false
        let testRow = row([testButton, testSpinner, testLabel])

        let stack = NSStackView(views: [header, explainLabel, providerRow, urlRow, keyRow, keyStateRow, modelRow,
                                        contextRow, testRow, privacyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: keyRow)
        stack.setCustomSpacing(16, after: explainLabel)
        stack.setCustomSpacing(16, after: contextRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for view in [header, explainLabel, urlRow, keyRow, keyStateRow, modelRow, testRow, privacyLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        testLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        titleLabel.textColor = theme.foreground
        explainLabel.textColor = theme.subtle
        keyStateLabel.textColor = theme.subtle
        privacyLabel.textColor = theme.subtle
        fieldLabels.forEach { $0.textColor = theme.subtle }
        reload()
    }

    private func reload() {
        let preset = AIProviderPreset.matching(AISettings.baseURL)
        providerPopup.selectItem(withTitle: preset?.name ?? Self.customTitle)
        if baseURLField.currentEditor() == nil { baseURLField.stringValue = AISettings.baseURL }
        if modelField.currentEditor() == nil { modelField.stringValue = AISettings.model }
        modelField.placeholderString = preset.map { "例如 \($0.modelHint)，以服务商文档为准" } ?? "模型名称"

        statusLabel.stringValue = AISettings.isConfigured ? "已启用" : "未设置"
        statusLabel.textColor = AISettings.isConfigured ? theme.palette[2] : theme.subtle
        let key = AISettings.apiKey
        if let key {
            keyStateLabel.stringValue = "已保存：\(Self.masked(key))，加密保存在本机"
        } else if preset?.needsKey == false {
            keyStateLabel.stringValue = "本机服务一般不需要 API Key，可以留空。"
        } else {
            keyStateLabel.stringValue = "在服务商控制台创建 API Key，保存后加密存放在本机。"
        }
        removeKeyButton.isHidden = key == nil
        let lines = AISettings.contextLines
        contextPopup.selectItem(at: Self.contextChoices.firstIndex(of: lines) ?? 1)
        let target = AISettings.baseURL.isEmpty ? "你设置的 AI 服务" : "AI 服务（\(AISettings.baseURL)）"
        privacyLabel.stringValue = "提问时，终端最近 \(lines) 行输出、当前目录和主机地址会发送到\(target)。"
            + "屏幕上有密码、密钥等敏感内容时，请先清屏（⌘K）再提问。"
    }

    private static func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(5)) + "…" + String(key.suffix(4))
    }

    @objc private func settingsChanged() {
        reload()
    }

    @objc private func providerChosen(_ sender: Any?) {
        let index = providerPopup.indexOfSelectedItem
        guard index >= 0, index < AIProviderPreset.all.count else {
            // "Custom": leave the address for the user to type.
            window?.makeFirstResponder(baseURLField)
            return
        }
        let preset = AIProviderPreset.all[index]
        AISettings.baseURL = preset.baseURL
        baseURLField.stringValue = preset.baseURL
        reload()
    }

    @objc private func saveKey(_ sender: Any?) {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if AISettings.setAPIKey(key) {
            keyField.stringValue = ""
            testLabel.stringValue = ""
        } else {
            testLabel.stringValue = "保存失败：无法写入本机凭据。"
            testLabel.textColor = theme.palette[1]
        }
    }

    @objc private func removeKey(_ sender: Any?) {
        AISettings.setAPIKey(nil)
    }

    @objc private func modelEdited(_ sender: Any?) {
        AISettings.model = modelField.stringValue
    }

    @objc private func baseURLEdited(_ sender: Any?) {
        AISettings.baseURL = baseURLField.stringValue
    }

    @objc private func contextChosen(_ sender: Any?) {
        let index = contextPopup.indexOfSelectedItem
        guard index >= 0, index < Self.contextChoices.count else { return }
        AISettings.contextLines = Self.contextChoices[index]
    }

    /// Sends a one-word request to check the address, key and model.
    @objc private func test(_ sender: Any?) {
        modelEdited(nil)
        baseURLEdited(nil)
        testTask?.cancel()
        testSpinner.startAnimation(nil)
        testButton.isEnabled = false
        testLabel.stringValue = "正在连接 \(AISettings.model)…"
        testLabel.textColor = theme.subtle
        testTask = Task {
            do {
                let response = try await AIClient.stream(
                    system: "Reply with the single word OK.",
                    messages: [.user("ping")]
                ) { _ in }
                testLabel.stringValue = "连接成功：\(response.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))"
                testLabel.textColor = theme.palette[2]
            } catch {
                testLabel.stringValue = (error as? AIError)?.localizedDescription ?? error.localizedDescription
                testLabel.textColor = theme.palette[1]
            }
            testSpinner.stopAnimation(nil)
            testButton.isEnabled = true
        }
    }
}

extension AISettingsView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === modelField { modelEdited(nil) }
        if field === baseURLField { baseURLEdited(nil) }
    }
}
