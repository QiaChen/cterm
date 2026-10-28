#if DEBUG
import AppKit
import Foundation

/// Hidden check of the AI client and conversation against a local mock of the
/// Messages API: `CTERM_AI_BASE_URL=http://127.0.0.1:PORT CTERM_AI_KEY=test cTerm --ai-smoke`
@MainActor
enum AISmokeTest {
    static func run() -> Never {
        URLProtocol.registerClass(AIMockProtocol.self)
        setenv("CTERM_AI_BASE_URL", AIMockProtocol.baseURL, 1)
        setenv("CTERM_AI_KEY", "test", 1)
        setenv("CTERM_AI_MODEL", "mock-model", 1)
        Task { @MainActor in
            do {
                try await checks()
                print("AI SMOKE OK")
                exit(0)
            } catch {
                print("FAILED: \(error)")
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("TIMEOUT")
            exit(3)
        }
        NSApplication.shared.run()
        exit(0)
    }

    private struct Failure: Error { let message: String }

    private static func check(_ condition: Bool, _ message: String) throws {
        print(condition ? "  ok   \(message)" : "  FAIL \(message)")
        if !condition { throw Failure(message: message) }
    }

    private static func waitIdle(_ conversation: AIConversation) async {
        while conversation.isBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private static func checks() async throws {
        let context = AITerminalContext(session: "SSH 远程主机：root@10.0.0.2:22", workingDirectory: "/root/w",
                                        screen: "root@box:~/w# ls\na.tar.gz", isFullScreenProgram: false)
        let conversation = AIConversation()
        var updates = 0
        conversation.onChange = { updates += 1 }
        conversation.send("帮我把 a.tar.gz 解压到当前目录", context: context)
        await waitIdle(conversation)
        let turn = conversation.turns[0]
        try check(turn.state == .done, "first turn finished (\(turn.state))")
        try check(updates > 5, "reply streamed in pieces (\(updates) updates)")
        let commands = AIReplySegment.parse(turn.reply).compactMap { segment -> String? in
            if case .code(let code, true, true) = segment { return code }
            return nil
        }
        try check(commands == ["tar -xzf a.tar.gz", "ls -la"], "two runnable commands parsed: \(commands)")

        conversation.send("第二个问题", context: context)
        await waitIdle(conversation)
        try check(conversation.turns[1].state == .done, "second turn finished")
        let second = AIMockProtocol.requests[1]
        let history = second.body["messages"] as? [[String: Any]] ?? []
        try check(history.map { $0["role"] as? String ?? "" } == ["system", "user", "assistant", "user"],
                  "system prompt then history in order")
        try check((history[0]["content"] as? String)?.contains("cTerm") == true, "system prompt sent as a message")
        func firstUser(_ body: [String: Any]) -> String? {
            (body["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "user" }?["content"] as? String
        }
        try check(firstUser(second.body) == firstUser(AIMockProtocol.requests[0].body), "first question replayed unchanged")
        let firstText = firstUser(second.body) ?? ""
        try check(firstText.contains("<terminal>") && firstText.contains("当前目录：/root/w"), "context sent with the question")
        let replayed = history[2]["content"] as? String ?? ""
        try check(replayed == conversation.turns[0].reply && !replayed.contains("先想一想"),
                  "answer replayed without the reasoning text")
        let headers = second.headers
        try check(headers["Authorization"] == "Bearer test", "bearer key header")
        try check(second.body["model"] as? String == "mock-model" && second.body["stream"] as? Bool == true,
                  "model and streaming")
        try check(AIMockProtocol.requests[0].url?.hasSuffix("/v1/chat/completions") == true, "chat completions endpoint")

        conversation.send("please refuse", context: context)
        await waitIdle(conversation)
        if case .failed(let message) = conversation.turns[2].state {
            try check(message.contains("拒绝"), "refusal shown: \(message)")
        } else {
            try check(false, "refusal should fail the turn")
        }
        conversation.send("第二 after refusal", context: context)
        await waitIdle(conversation)
        try check(conversation.turns[3].state == .done, "conversation continues after a refusal")
        let afterRefusal = AIMockProtocol.requests.last?.body["messages"] as? [[String: Any]] ?? []
        try check(afterRefusal.count == 6, "refused turn left out of the history (\(afterRefusal.count) messages)")

        // Streaming segments: an unclosed fence is a command still arriving.
        let partial = AIReplySegment.parse("运行：\n```bash\ntar -x")
        try check(partial == [.text("运行："), .code("tar -x", runnable: true, complete: false)], "open fence is incomplete")
        let text = AIReplySegment.parse("```text\noutput\n```")
        try check(text == [.code("output", runnable: false, complete: true)], "text block is not runnable")
        try check(AIReplySegment.looksDestructive("rm -rf build"), "rm -rf flagged")
        try check(!AIReplySegment.looksDestructive("tar -xzf a.tar.gz"), "tar not flagged")
        try check(SessionViewController.directory(fromTitle: "root@web1: /var/log") == "/var/log", "title path parsed")
        try check(SessionViewController.directory(fromTitle: "cole@mac:~/w") == "~/w", "home title path parsed")
        try check(SessionViewController.directory(fromTitle: "vim") == nil, "plain title ignored")

        setenv("CTERM_AI_KEY", "bad-key", 1)
        let bad = AIConversation()
        bad.send("ping", context: context)
        await waitIdle(bad)
        if case .failed(let message) = bad.turns[0].state {
            try check(message.contains("401"), "401 explained: \(message)")
        } else {
            try check(false, "bad key should fail")
        }

        setenv("CTERM_AI_BASE_URL", "http://127.0.0.1:1", 1)
        let offline = AIConversation()
        offline.send("ping", context: context)
        await waitIdle(offline)
        if case .failed(let message) = offline.turns[0].state {
            try check(message.contains("无法连接"), "unreachable endpoint explained: \(message)")
        } else {
            try check(false, "unreachable endpoint should fail")
        }

        let cancelled = AIConversation()
        setenv("CTERM_AI_BASE_URL", AIMockProtocol.baseURL, 1)
        setenv("CTERM_AI_KEY", "test", 1)
        cancelled.send("帮我解压", context: context)
        try? await Task.sleep(nanoseconds: 150_000_000)
        cancelled.cancel()
        await waitIdle(cancelled)
        setenv("CTERM_AI_BASE_URL", "https://api.deepseek.com/v1/chat/completions", 1)
        try check(AISettings.endpoint?.absoluteString == "https://api.deepseek.com/v1/chat/completions",
                  "pasted full endpoint kept as is")
        setenv("CTERM_AI_BASE_URL", "http://localhost:11434/v1", 1)
        try check(AISettings.endpoint?.absoluteString == "http://localhost:11434/v1/chat/completions", "path appended")
        setenv("CTERM_AI_MODEL", "", 1)
        try check(!AISettings.isConfigured, "no model means not configured")
        setenv("CTERM_AI_MODEL", "mock-model", 1)
        setenv("CTERM_AI_BASE_URL", AIMockProtocol.baseURL, 1)
        try check(cancelled.turns[0].state == .cancelled, "stop cancels the stream (\(cancelled.turns[0].state))")
    }
}
#endif
