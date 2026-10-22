import Foundation

/// Claude through Anthropic's native Messages API (raw HTTP; there is no official Swift SDK).
/// The rest of the app speaks the OpenAI chat format, so requests are translated here and the
/// SSE stream is mapped back to `StreamEvent`s.
enum AnthropicClient {
    /// Models where `fallbacks: "default"` is accepted on the Claude API.
    static func supportsFallbacks(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains(model)
    }

    /// Adaptive thinking and `output_config.effort` exist on Claude 4.6 and newer (and every 5.x).
    static func supportsAdaptiveThinking(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.contains("haiku-4") || m.contains("claude-3") { return false }
        return m.contains("-5") || m.contains("4-6") || m.contains("4-7") || m.contains("4-8")
    }

    static func stream(body: [String: Any]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try ChatClient.makeRequest(provider: .anthropic, path: "/messages", body: convert(body))
                    if let beta = body["_anthropic_beta"] as? String { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    if let http, let rl = RateLimitInfo(headers: http.allHeaderFields) { continuation.yield(.rateLimit(rl)) }
                    if let http, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
                        throw APIError(status: http.statusCode, message: ChatClient.errorMessage(from: data))
                    }

                    var blocks: [Int: [String: Any]] = [:]
                    var toolJSON: [Int: String] = [:]
                    var stopReason: String?
                    var usage = TokenUsage()

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                        guard let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                        let index = event["index"] as? Int ?? 0
                        switch event["type"] as? String {
                        case "message_start":
                            if let u = (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                                usage.prompt = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                            }
                        case "content_block_start":
                            let block = event["content_block"] as? [String: Any] ?? [:]
                            blocks[index] = block
                            if ["thinking", "redacted_thinking"].contains(block["type"] as? String) {
                                continuation.yield(.reasoning(""))   // starts the "Thinking" timer
                            }
                            if block["type"] as? String == "tool_use" { toolJSON[index] = "" }
                        case "content_block_delta":
                            let delta = event["delta"] as? [String: Any] ?? [:]
                            switch delta["type"] as? String {
                            case "text_delta":
                                let t = delta["text"] as? String ?? ""
                                let old = blocks[index]?["text"] as? String ?? ""
                                blocks[index]?["text"] = old + t
                                if !t.isEmpty { continuation.yield(.content(t)) }
                            case "thinking_delta":
                                let t = delta["thinking"] as? String ?? ""
                                let old = blocks[index]?["thinking"] as? String ?? ""
                                blocks[index]?["thinking"] = old + t
                                continuation.yield(.reasoning(t))
                            case "signature_delta":
                                let old = blocks[index]?["signature"] as? String ?? ""
                                blocks[index]?["signature"] = old + (delta["signature"] as? String ?? "")
                            case "input_json_delta":
                                toolJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                            default: break
                            }
                        case "content_block_stop":
                            if let json = toolJSON[index] {
                                // With eager input streaming the API doesn't validate the JSON, so guard the parse.
                                let parsed = json.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
                                blocks[index]?["input"] = parsed ?? [String: Any]()
                            }
                        case "message_delta":
                            if let d = event["delta"] as? [String: Any] { stopReason = d["stop_reason"] as? String ?? stopReason }
                            if let u = event["usage"] as? [String: Any] { usage.completion = u["output_tokens"] as? Int ?? usage.completion }
                        case "error":
                            let err = event["error"] as? [String: Any]
                            throw APIError(status: err?["type"] as? String == "overloaded_error" ? 529 : 0,
                                           message: err?["message"] as? String ?? "Claude returned an error")
                        default: break
                        }
                    }

                    continuation.yield(.usage(usage))
                    let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
                    if let raw = JSONValue(any: ordered) { continuation.yield(.providerBlocks(raw)) }
                    if ordered.contains(where: { $0["type"] as? String == "fallback" }) {
                        continuation.yield(.notice("_(Answered by a fallback model.)_"))
                    }
                    if stopReason == "refusal" {
                        continuation.yield(.notice("Claude declined to continue with this request."))
                    }
                    let calls = ordered.filter { $0["type"] as? String == "tool_use" }.map { b -> ToolCall in
                        let input = b["input"] ?? [String: Any]()
                        let args = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        return ToolCall(id: b["id"] as? String ?? UUID().uuidString, name: b["name"] as? String ?? "", arguments: args)
                    }
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: OpenAI chat format → Messages API

    static func convert(_ body: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["model": body["model"] ?? "", "max_tokens": 64_000, "stream": true]
        for key in ["thinking", "output_config", "fallbacks"] { if let v = body[key] { out[key] = v } }

        var system: [String] = []
        var messages: [[String: Any]] = []
        func appendUser(_ blocks: [[String: Any]]) {
            let content = blocks.isEmpty ? [["type": "text", "text": "(empty message)"]] : blocks
            if let last = messages.last, last["role"] as? String == "user", let existing = last["content"] as? [[String: Any]] {
                messages[messages.count - 1]["content"] = existing + content
            } else {
                messages.append(["role": "user", "content": content])
            }
        }

        for m in body["messages"] as? [[String: Any]] ?? [] {
            switch m["role"] as? String {
            case "system":
                if let t = m["content"] as? String { system.append(t) }
            case "user":
                appendUser(contentBlocks(m["content"]))
            case "assistant":
                if let raw = m["anthropic_blocks"] as? [Any], !raw.isEmpty {
                    // Send Claude's own blocks back unchanged (thinking signatures included).
                    messages.append(["role": "assistant", "content": raw])
                    continue
                }
                var blocks: [[String: Any]] = []
                if let t = m["content"] as? String, !t.isEmpty { blocks.append(["type": "text", "text": t]) }
                for tc in m["tool_calls"] as? [[String: Any]] ?? [] {
                    let fn = tc["function"] as? [String: Any] ?? [:]
                    let args = fn["arguments"] as? String ?? "{}"
                    let input = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) ?? [String: Any]()
                    blocks.append(["type": "tool_use", "id": tc["id"] ?? "", "name": fn["name"] ?? "", "input": input])
                }
                if !blocks.isEmpty { messages.append(["role": "assistant", "content": blocks]) }
            case "tool":
                appendUser([["type": "tool_result", "tool_use_id": m["tool_call_id"] ?? "",
                             "content": (m["content"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no output)"]])
            default:
                break
            }
        }
        if !system.isEmpty { out["system"] = system.joined(separator: "\n\n") }
        out["messages"] = messages

        if let tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            out["tools"] = tools.compactMap { t -> [String: Any]? in
                guard let fn = t["function"] as? [String: Any], let name = fn["name"] else { return nil }
                return ["name": name, "description": fn["description"] ?? "",
                        "input_schema": fn["parameters"] ?? ["type": "object", "properties": [String: Any]()],
                        "eager_input_streaming": true]
            }
        }
        return out
    }

    private static func contentBlocks(_ content: Any?) -> [[String: Any]] {
        if let s = content as? String { return s.isEmpty ? [] : [["type": "text", "text": s]] }
        guard let parts = content as? [[String: Any]] else { return [] }
        return parts.compactMap { part in
            switch part["type"] as? String {
            case "text":
                let t = part["text"] as? String ?? ""
                return t.isEmpty ? nil : ["type": "text", "text": t]
            case "image_url":
                guard let url = (part["image_url"] as? [String: Any])?["url"] as? String,
                      url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
                let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]   // "image/png;base64"
                let mime = header.split(separator: ";").first.map(String.init) ?? "image/png"
                return ["type": "image", "source": ["type": "base64", "media_type": mime, "data": String(url[url.index(after: comma)...])]]
            default:
                return nil
            }
        }
    }
}
