import Foundation

struct AIMessage {
    let role: String
    let content: String

    static func user(_ text: String) -> AIMessage { AIMessage(role: "user", content: text) }
    static func assistant(_ text: String) -> AIMessage { AIMessage(role: "assistant", content: text) }

    var json: [String: Any] { ["role": role, "content": content] }
}

struct AIResponse {
    let text: String
    let finishReason: String?
}

enum AIError: LocalizedError {
    case notConfigured
    case badURL
    case http(status: Int, message: String)
    case stream(String)
    case filtered

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有设置 AI 服务。请在“设置 → AI”中填写 API 地址和模型。"
        case .badURL:
            return "API 地址无效，请在“设置 → AI”中检查。"
        case .http(let status, let message):
            switch status {
            case 401: return "API Key 无效或已过期（401）。"
            case 403: return "没有权限使用这个模型（403）：\(message)"
            case 404: return "找不到模型或接口（404），请检查 API 地址和模型名称：\(message)"
            case 429: return "请求太频繁或额度已用完（429），请稍后再试。"
            default:
                return message.isEmpty ? "请求失败（HTTP \(status)）。" : "请求失败（HTTP \(status)）：\(message)"
            }
        case .stream(let message):
            return "AI 服务返回错误：\(message)"
        case .filtered:
            return "AI 服务拒绝了这个请求（内容过滤）。可以换一种说法再试。"
        }
    }
}

/// Talks to any service with an OpenAI-compatible chat completions API
/// (OpenAI, DeepSeek, Qwen, Kimi, GLM, Ollama…), streaming the reply.
@MainActor
enum AIClient {
    /// Sends the conversation and streams the reply. `onText` gets the whole
    /// text so far each time it grows.
    static func stream(system: String, messages: [AIMessage],
                       onText: @escaping (String) -> Void) async throws -> AIResponse {
        guard AISettings.isConfigured else { throw AIError.notConfigured }
        guard let url = AISettings.endpoint else { throw AIError.badURL }
        let body: [String: Any] = [
            "model": AISettings.model,
            "stream": true,
            "messages": [["role": "system", "content": system]] + messages.map(\.json)
        ]
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = AISettings.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            throw AIError.http(status: status, message: errorMessage(in: data))
        }

        var text = ""
        var finishReason: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = event["error"] as? [String: Any] {
                throw AIError.stream(error["message"] as? String ?? "未知错误")
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
            // Reasoning models may also stream "reasoning_content"; only the
            // answer is shown.
            if let delta = choice["delta"] as? [String: Any], let piece = delta["content"] as? String, !piece.isEmpty {
                text += piece
                onText(text)
            }
            if let reason = choice["finish_reason"] as? String {
                finishReason = reason
            }
        }
        if finishReason == "content_filter" { throw AIError.filtered }
        return AIResponse(text: text, finishReason: finishReason)
    }

    private static func errorMessage(in data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["error"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        return String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
