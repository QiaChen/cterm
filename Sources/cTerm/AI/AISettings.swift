import Foundation

extension Notification.Name {
    static let ctermAISettingsDidChange = Notification.Name("cterm.aiSettingsDidChange")
    /// Opens Settings on the AI tab.
    static let ctermShowAISettings = Notification.Name("cterm.showAISettings")
}

/// A service that speaks the OpenAI chat completions API. Picking one fills
/// in its address; the model name is the user's choice, since each service
/// renames its models often.
struct AIProviderPreset {
    let name: String
    let baseURL: String
    /// Shown greyed in the model field as an example.
    let modelHint: String
    let needsKey: Bool

    static let all: [AIProviderPreset] = [
        AIProviderPreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", modelHint: "gpt-4o-mini", needsKey: true),
        AIProviderPreset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", modelHint: "deepseek-chat", needsKey: true),
        AIProviderPreset(name: "通义千问（阿里云百炼）", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                         modelHint: "qwen-plus", needsKey: true),
        AIProviderPreset(name: "Kimi（月之暗面）", baseURL: "https://api.moonshot.cn/v1", modelHint: "moonshot-v1-8k", needsKey: true),
        AIProviderPreset(name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", modelHint: "glm-4-flash", needsKey: true),
        AIProviderPreset(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", modelHint: "Qwen/Qwen2.5-7B-Instruct",
                         needsKey: true),
        AIProviderPreset(name: "Ollama（本机）", baseURL: "http://localhost:11434/v1", modelHint: "qwen2.5", needsKey: false)
    ]

    static func matching(_ baseURL: String) -> AIProviderPreset? {
        all.first { $0.baseURL == baseURL }
    }
}

/// AI assistant preferences. The API key is a secret, so it lives in the
/// encrypted credential store; the rest are plain UserDefaults.
enum AISettings {
    static let defaultContextLines = 120

    private static let defaults = UserDefaults.standard
    private static let modelKey = "cterm.ai.model"
    private static let baseURLKey = "cterm.ai.baseURL"
    private static let contextLinesKey = "cterm.ai.contextLines"
    private static let keyAccount = "api-key"
    private static let keyService = "ai"

    static var model: String {
        get {
            #if DEBUG
            if let model = ProcessInfo.processInfo.environment["CTERM_AI_MODEL"] { return model }
            #endif
            return nonEmpty(defaults.string(forKey: modelKey))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set { set(nonEmpty(newValue.trimmingCharacters(in: .whitespacesAndNewlines)), forKey: modelKey) }
    }

    /// Like https://api.deepseek.com/v1; requests go to …/chat/completions.
    static var baseURL: String {
        get {
            #if DEBUG
            if let url = ProcessInfo.processInfo.environment["CTERM_AI_BASE_URL"] { return url }
            #endif
            return nonEmpty(defaults.string(forKey: baseURLKey)) ?? ""
        }
        set {
            var value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            while value.hasSuffix("/") { value.removeLast() }
            set(nonEmpty(value), forKey: baseURLKey)
        }
    }

    /// The full endpoint. An address pasted with /chat/completions already on
    /// the end is used as it is.
    static var endpoint: URL? {
        let base = baseURL
        guard !base.isEmpty else { return nil }
        let full = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: full), let scheme = url.scheme, scheme.hasPrefix("http") else { return nil }
        return url
    }

    /// How many lines of terminal output go with each question.
    static var contextLines: Int {
        get {
            let value = defaults.integer(forKey: contextLinesKey)
            return value > 0 ? min(max(value, 20), 1000) : defaultContextLines
        }
        set { set(newValue == defaultContextLines ? nil : newValue, forKey: contextLinesKey) }
    }

    static var apiKey: String? {
        #if DEBUG
        if let key = ProcessInfo.processInfo.environment["CTERM_AI_KEY"] { return key }
        #endif
        return nonEmpty(CredentialStore.loadItem(account: keyAccount, service: keyService))
    }

    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        let ok: Bool
        if let key = nonEmpty(key?.trimmingCharacters(in: .whitespacesAndNewlines)) {
            ok = CredentialStore.saveItem(key, account: keyAccount, service: keyService)
        } else {
            CredentialStore.deleteItem(account: keyAccount, service: keyService)
            ok = true
        }
        NotificationCenter.default.post(name: .ctermAISettingsDidChange, object: nil)
        return ok
    }

    /// An address and a model are required; the key is not, since a local
    /// server such as Ollama takes none.
    static var isConfigured: Bool { endpoint != nil && !model.isEmpty }

    private static func set(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .ctermAISettingsDidChange, object: nil)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
