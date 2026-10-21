import Foundation

struct APIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { status > 0 ? "HTTP \(status): \(message)" : message }
}

struct RateLimitInfo: Codable, Hashable {
    var limitRequests: Int?
    var remainingRequests: Int?
    var resetRequests: String?
    var limitTokens: Int?
    var remainingTokens: Int?
    var resetTokens: String?
    var updatedAt = Date()

    init?(headers: [AnyHashable: Any]) {
        func h(_ k: String) -> String? {
            for (key, v) in headers where (key as? String)?.lowercased() == k { return v as? String }
            return nil
        }
        limitRequests = h("x-ratelimit-limit-requests").flatMap(Int.init)
        remainingRequests = h("x-ratelimit-remaining-requests").flatMap(Int.init)
        resetRequests = h("x-ratelimit-reset-requests")
        limitTokens = h("x-ratelimit-limit-tokens").flatMap(Int.init)
        remainingTokens = h("x-ratelimit-remaining-tokens").flatMap(Int.init)
        resetTokens = h("x-ratelimit-reset-tokens")
        if limitRequests == nil && limitTokens == nil && remainingRequests == nil { return nil }
    }
}

struct TokenUsage { var prompt = 0; var completion = 0 }

enum StreamEvent {
    case content(String)
    case reasoning(String)
    case toolCalls([ToolCall])   // final, assembled
    case usage(TokenUsage)
    case rateLimit(RateLimitInfo)
}

/// Splits `<think>…</think>` / `<thought>…</thought>` out of streamed content.
struct ThinkTagSplitter {
    private var buffer = ""
    private var inside = false
    private static let opens = ["<think>", "<thought>"]
    private static let closes = ["</think>", "</thought>"]

    mutating func feed(_ s: String) -> (content: String, reasoning: String) {
        buffer += s
        var content = "", reasoning = ""
        while !buffer.isEmpty {
            let tags = inside ? Self.closes : Self.opens
            if let r = tags.compactMap({ buffer.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                let before = String(buffer[..<r.lowerBound])
                if inside { reasoning += before } else { content += before }
                buffer = String(buffer[r.upperBound...])
                inside.toggle()
                continue
            }
            // Keep a possible partial tag at the end of the buffer.
            var keep = 0
            for tag in tags {
                for n in stride(from: min(tag.count - 1, buffer.count), through: 1, by: -1)
                where buffer.hasSuffix(String(tag.prefix(n))) { keep = max(keep, n); break }
            }
            let emit = String(buffer.dropLast(keep))
            if inside { reasoning += emit } else { content += emit }
            buffer = String(buffer.suffix(keep))
            break
        }
        return (content, reasoning)
    }

    mutating func flush() -> (content: String, reasoning: String) {
        defer { buffer = "" }
        return inside ? ("", buffer) : (buffer, "")
    }
}

enum ChatClient {
    static func apiKey(for provider: ProviderID) -> String? {
        provider == .local ? nil : Keychain.get(provider.rawValue)
    }

    static func makeRequest(provider: ProviderID, path: String, body: [String: Any]?) throws -> URLRequest {
        guard let url = URL(string: provider.baseURL + path) else { throw APIError(status: 0, message: "Bad base URL") }
        // Idle timeout: cloud servers that stall get cut off; local engines may need longer for big prompts.
        var req = URLRequest(url: url, timeoutInterval: provider == .local ? 600 : 60)
        if let key = apiKey(for: provider) { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if provider == .openrouter {
            req.setValue("https://github.com/Agamemnon-Intelligence/Synapse-macOS", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("Synapse", forHTTPHeaderField: "X-Title")
        }
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            let o = (obj as? [Any])?.first ?? obj
            if let d = o as? [String: Any] {
                if let e = d["error"] as? [String: Any], let m = e["message"] as? String { return m }
                if let e = d["error"] as? String { return e }
                if let m = d["message"] as? String { return m }
            }
        }
        return String(decoding: data.prefix(600), as: UTF8.self)
    }

    /// Streams an OpenAI-compatible chat completion.
    static func stream(provider: ProviderID, body: [String: Any]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body = body
                    body["stream"] = true
                    if provider != .local { body["stream_options"] = ["include_usage": true] }
                    let req = try makeRequest(provider: provider, path: "/chat/completions", body: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let http = response as? HTTPURLResponse
                    if let http, let rl = RateLimitInfo(headers: http.allHeaderFields) {
                        continuation.yield(.rateLimit(rl))
                    }
                    if let http, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
                        throw APIError(status: http.statusCode, message: errorMessage(from: data))
                    }

                    var splitter = ThinkTagSplitter()
                    var calls: [ToolCall] = []
                    var nonSSE = Data()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else {
                            if !line.isEmpty { nonSSE.append(Data((line + "\n").utf8)) }
                            continue
                        }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        if let err = obj["error"] {
                            let data = (try? JSONSerialization.data(withJSONObject: ["error": err])) ?? Data()
                            throw APIError(status: 0, message: errorMessage(from: data))
                        }
                        if let u = obj["usage"] as? [String: Any] {
                            continuation.yield(.usage(TokenUsage(prompt: u["prompt_tokens"] as? Int ?? 0,
                                                                 completion: u["completion_tokens"] as? Int ?? 0)))
                        }
                        guard let choice = (obj["choices"] as? [[String: Any]])?.first,
                              let delta = choice["delta"] as? [String: Any] else { continue }
                        for key in ["reasoning_content", "reasoning", "thinking"] {
                            if let r = delta[key] as? String, !r.isEmpty { continuation.yield(.reasoning(r)) }
                        }
                        if let c = delta["content"] as? String, !c.isEmpty {
                            let (content, reasoning) = splitter.feed(c)
                            if !reasoning.isEmpty { continuation.yield(.reasoning(reasoning)) }
                            if !content.isEmpty { continuation.yield(.content(content)) }
                        }
                        if let tcs = delta["tool_calls"] as? [[String: Any]] {
                            for tc in tcs {
                                let fn = tc["function"] as? [String: Any] ?? [:]
                                let id = tc["id"] as? String
                                let slot: Int
                                if let idx = tc["index"] as? Int {
                                    slot = idx
                                } else if let id, !calls.contains(where: { $0.id == id }) {
                                    slot = calls.count
                                } else if let id, let existing = calls.firstIndex(where: { $0.id == id }) {
                                    slot = existing
                                } else {
                                    slot = max(0, calls.count - 1)
                                }
                                while calls.count <= slot {
                                    calls.append(ToolCall(id: "call_\(UUID().uuidString.prefix(8))", name: "", arguments: ""))
                                }
                                if let id, !id.isEmpty { calls[slot].id = id }
                                if let n = fn["name"] as? String, !n.isEmpty { calls[slot].name = n }
                                if let a = fn["arguments"] as? String { calls[slot].arguments += a }
                                if let extra = tc["extra_content"], let j = JSONValue(any: extra) { calls[slot].extra = j }
                            }
                        }
                    }
                    if !nonSSE.isEmpty && calls.isEmpty {
                        // Some servers ignore stream=true; handle a plain JSON reply.
                        if let obj = try? JSONSerialization.jsonObject(with: nonSSE) as? [String: Any],
                           let msg = ((obj["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any] {
                            if let r = msg["reasoning_content"] as? String { continuation.yield(.reasoning(r)) }
                            if let c = msg["content"] as? String {
                                let (content, reasoning) = splitter.feed(c)
                                if !reasoning.isEmpty { continuation.yield(.reasoning(reasoning)) }
                                if !content.isEmpty { continuation.yield(.content(content)) }
                            }
                        } else if calls.isEmpty {
                            throw APIError(status: 0, message: errorMessage(from: nonSSE))
                        }
                    }
                    let rest = splitter.flush()
                    if !rest.reasoning.isEmpty { continuation.yield(.reasoning(rest.reasoning)) }
                    if !rest.content.isEmpty { continuation.yield(.content(rest.content)) }
                    let finished = calls.filter { !$0.name.isEmpty }
                    if !finished.isEmpty { continuation.yield(.toolCalls(finished)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Lists model IDs from a provider's /models endpoint.
    static func listModels(provider: ProviderID) async throws -> [ModelRef] {
        let req = try makeRequest(provider: provider, path: "/models", body: nil)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError(status: http.statusCode, message: errorMessage(from: data))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        var refs: [ModelRef] = []
        for m in list {
            guard var id = m["id"] as? String else { continue }
            if id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
            if !isChatModel(provider: provider, id: id, raw: m) { continue }
            let name = (m["name"] as? String) ?? id
            refs.append(ModelRef(provider: provider, id: id, name: name, vision: guessVision(provider: provider, id: id, raw: m)))
        }
        return refs.sorted { rank(provider, $0.id) < rank(provider, $1.id) }
    }

    private static func isChatModel(provider: ProviderID, id: String, raw: [String: Any]) -> Bool {
        let l = id.lowercased()
        let excluded = ["tts", "embedding", "embed", "veo", "lyria", "imagen", "-image", "image-", "nano-banana", "live",
                        "audio", "aqa", "robotics", "transcribe", "whisper", "deep-research", "antigravity",
                        "computer-use", "guard", "moderation", "orpheus", "playai", "distil-whisper", "translate", "omni"]
        if excluded.contains(where: { l.contains($0) }) { return false }
        if provider == .openrouter { return l.hasSuffix(":free") }
        if provider == .google { return l.hasPrefix("gemini") || l.hasPrefix("gemma") }
        return true
    }

    private static func guessVision(provider: ProviderID, id: String, raw: [String: Any]) -> Bool {
        let l = id.lowercased()
        if provider == .google { return true }
        if let arch = raw["architecture"] as? [String: Any], let mods = arch["input_modalities"] as? [String] {
            return mods.contains("image")
        }
        return l.contains("vision") || l.contains("llama-4") || l.contains("-vl") || l.contains("gemma-3") || l.contains("gemma-4")
    }

    private static func rank(_ provider: ProviderID, _ id: String) -> String {
        let l = id.lowercased()
        let preferred: [String]
        switch provider {
        case .google: preferred = ["gemini-3.8-flash", "gemini-flash-latest", "gemini-3.7-flash", "gemini-pro-latest", "gemini-3.1-pro", "gemini-flash-lite-latest"]
        case .groq: preferred = ["openai/gpt-oss-120b", "llama-3.3-70b", "moonshotai/kimi", "qwen/qwen3", "openai/gpt-oss-20b", "meta-llama/llama-4"]
        default: preferred = []
        }
        if let i = preferred.firstIndex(where: { l.hasPrefix($0) }) { return "0\(i)" + l }
        return "1" + l
    }
}
