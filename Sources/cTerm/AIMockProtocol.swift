#if DEBUG
import Foundation

/// Serves canned streaming replies for https://mock.cterm.test, so the AI
/// client can be checked without a network or an API key. Requests are kept
/// for the checks to inspect.
final class AIMockProtocol: URLProtocol, @unchecked Sendable {
    static let baseURL = "https://mock.cterm.test/v1"
    nonisolated(unsafe) static var requests: [(url: String?, headers: [String: String], body: [String: Any])] = []
    private static let lock = NSLock()

    static let reply = """
        当前目录下有 `a.tar.gz`，它是 gzip 压缩的 tar 包。用 **tar** 解压到当前目录就行，`-x` 表示解压，`-z` 走 gzip，`-f` 后面跟文件名；如果包很大，可以再加 `-v` 看到每个解出来的文件，例如 /www/server/php/85/bin/php-fpm 这样的长路径也会逐行列出：

        ```bash
        tar -xzf a.tar.gz
        ```

        解压后可以查看里面的内容：

        ```bash
        ls -la
        ```

        如果解压出来的目录权限不对，再告诉我，我帮你调整。
        """

    /// For README screenshots: a question that runs for real on test.rebex.net.
    static let largestReply = """
        `ls -lS` 按文件大小从大到小排序，配合 `head` 只看前几行。目录里第一行是 total，所以取 6 行：

        ```bash
        ls -lS pub/example | head -n 6
        ```

        想看到 KB、MB 这样易读的大小，再加上 `-h`：

        ```bash
        ls -lhS pub/example | head -n 6
        ```
        """

    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mock.cterm.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let headers = request.allHTTPHeaderFields ?? [:]
        Self.lock.lock()
        Self.requests.append((request.url?.absoluteString, headers, body))
        Self.lock.unlock()

        let url = request.url!
        let key = headers["Authorization"] ?? ""
        if key == "Bearer bad-key" {
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1",
                                           headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let messages = body["messages"] as? [[String: Any]] ?? []
        let lastContent = messages.last?["content"] as? String ?? ""
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        func chunk(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
            ["id": "chatcmpl-mock", "object": "chat.completion.chunk",
             "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]]]
        }
        // A reasoning model streams its thinking first; it must not show.
        var events: [Any] = [chunk(["role": "assistant", "content": ""]),
                             chunk(["reasoning_content": "先想一想"])]
        if lastContent.contains("refuse") {
            events.append(chunk([:], finish: "content_filter"))
        } else {
            let text: String
            if lastContent.contains("<request>\nping") || lastContent == "ping" {
                text = "OK"
            } else if lastContent.contains("最大") {
                text = Self.largestReply
            } else if lastContent.contains("第二") {
                text = "已经解压好了，里面有 `a/` 目录。"
            } else {
                text = Self.reply
            }
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: 6, limitedBy: text.endIndex) ?? text.endIndex
                events.append(chunk(["content": String(text[index..<end])]))
                index = end
            }
            events.append(chunk([:], finish: "stop"))
        }
        events.append("[DONE]")

        DispatchQueue.global().async { [self] in
            for event in events {
                if cancelled { return }
                let json = event is String ? Data((event as! String).utf8)
                    : (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
                var chunk = Data("data: ".utf8)
                chunk.append(json)
                chunk.append(Data("\n\n".utf8))
                client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.025)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        cancelled = true
    }
}
#endif
