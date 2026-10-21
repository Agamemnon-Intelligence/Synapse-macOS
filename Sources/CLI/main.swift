import Foundation

// synapse — talk to any Synapse model (local or cloud) from Terminal.
// The Synapse app serves an OpenAI-compatible API on 127.0.0.1:11435; this tool is a thin client.

let base = ProcessInfo.processInfo.environment["SYNAPSE_URL"] ?? "http://127.0.0.1:11435"
let dim = "\u{001B}[2m", bold = "\u{001B}[1m", violet = "\u{001B}[38;5;141m", cyan = "\u{001B}[38;5;45m", red = "\u{001B}[31m", reset = "\u{001B}[0m"

func usage() {
    print("""
    \(violet)\(bold)◉ Synapse\(reset) — run AI models from Terminal

    \(bold)Usage\(reset)
      synapse chat [model] [--think off|normal|high|max]   Interactive chat
      synapse run <model> "prompt" [--think …]            One-shot answer (prompt can also come from stdin)
      synapse models                                      List available models
      synapse status                                      Check the Synapse app is running

    Models look like \(cyan)local/<id>\(reset), \(cyan)google/gemini-3.8-flash\(reset), \(cyan)groq/llama-3.3-70b-versatile\(reset).
    Leave the model out to use your default. In chat: /model <id>, /think <level>, /clear, /exit.
    """)
}

func serverUp() async -> Bool {
    guard let url = URL(string: base + "/health") else { return false }
    var req = URLRequest(url: url, timeoutInterval: 1.5)
    req.httpMethod = "GET"
    return (try? await URLSession.shared.data(for: req)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
}

func ensureServer() async {
    if await serverUp() { return }
    FileHandle.standardError.write(Data("\(dim)Starting Synapse…\(reset)\n".utf8))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", "com.athenesoftworks.synapse"]
    try? p.run()
    p.waitUntilExit()
    for _ in 0..<60 {
        if await serverUp() { return }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    FileHandle.standardError.write(Data("\(red)Couldn't reach Synapse at \(base). Open the app and make sure the local API server is on (Settings → Terminal & API).\(reset)\n".utf8))
    exit(1)
}

func listModels() async -> [(id: String, name: String)] {
    guard let (data, _) = try? await URLSession.shared.data(from: URL(string: base + "/v1/models")!),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = obj["data"] as? [[String: Any]] else { return [] }
    return list.compactMap { m in (m["id"] as? String).map { ($0, m["name"] as? String ?? $0) } }
}

/// Streams a reply and prints the answer (thinking is hidden). Returns the content.
func stream(model: String, messages: [[String: Any]], think: String?) async -> String? {
    var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
    if let think { body["synapse_think"] = think }
    var req = URLRequest(url: URL(string: base + "/v1/chat/completions")!, timeoutInterval: 900)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    do {
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var d = Data()
            for try await b in bytes { d.append(b) }
            let msg = String(decoding: d, as: UTF8.self)
            print("\(red)Error \(status): \(msg.prefix(800))\(reset)")
            return nil
        }
        var content = ""
        var inReasoning = false
        var inTag = false
        // Thoughts stay private: show a placeholder while the model thinks, then clear it.
        func emit(_ s: String, reasoning: Bool) {
            if reasoning {
                if !inReasoning { print("\(dim)Thinking…\(reset)", terminator: ""); fflush(stdout); inReasoning = true }
                return
            }
            if inReasoning { print("\r\u{001B}[K", terminator: ""); inReasoning = false }
            print(s, terminator: "")
            fflush(stdout)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] { print("\(red)\(err)\(reset)"); return nil }
            guard let delta = ((obj["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any] else { continue }
            for k in ["reasoning_content", "reasoning"] { if let r = delta[k] as? String, !r.isEmpty { emit(r, reasoning: true) } }
            if var c = delta["content"] as? String, !c.isEmpty {
                for open in ["<think>", "<thought>"] where c.contains(open) { c = c.replacingOccurrences(of: open, with: ""); inTag = true }
                if inTag {
                    for close in ["</think>", "</thought>"] where c.contains(close) {
                        let parts = c.components(separatedBy: close)
                        emit(parts[0], reasoning: true)
                        c = parts.dropFirst().joined(separator: close)
                        inTag = false
                    }
                    if inTag { emit(c, reasoning: true); continue }
                }
                if !c.isEmpty { emit(c, reasoning: false); content += c }
            }
        }
        print(reset)
        return content
    } catch {
        print("\(red)\(error.localizedDescription)\(reset)")
        return nil
    }
}

func parseThink(_ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: "--think"), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v == "normal" ? "standard" : v
}

func chat(model initial: String?, think initialThink: String?) async {
    let models = await listModels()
    var model = initial ?? ""
    var think = initialThink
    if model.isEmpty {
        model = models.first?.id ?? ""
    }
    if !model.isEmpty, !models.contains(where: { $0.id == model }), let m = models.first(where: { $0.id.hasSuffix("/" + model) || $0.name == model }) {
        model = m.id
    }
    print("\(violet)\(bold)◉ Synapse\(reset)  \(dim)model:\(reset) \(cyan)\(model.isEmpty ? "default" : model)\(reset)  \(dim)think:\(reset) \(think ?? "normal")")
    print("\(dim)/model <id> · /models · /think off|normal|high|max · /clear · /exit\(reset)\n")
    var messages: [[String: Any]] = []
    while true {
        print("\(violet)›\(reset) ", terminator: "")
        fflush(stdout)
        guard let line = readLine() else { break }
        let input = line.trimmingCharacters(in: .whitespaces)
        if input.isEmpty { continue }
        if input.hasPrefix("/") {
            let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "/exit", "/quit": return
            case "/clear": messages = []; print("\(dim)Cleared.\(reset)")
            case "/models": for m in await listModels() { print("  \(m.id)") }
            case "/model":
                if parts.count > 1 { model = parts[1]; print("\(dim)Model: \(model)\(reset)") }
            case "/think":
                if parts.count > 1 { think = parts[1] == "normal" ? "standard" : parts[1]; print("\(dim)Think: \(parts[1])\(reset)") }
            default: print("\(dim)Unknown command\(reset)")
            }
            continue
        }
        messages.append(["role": "user", "content": input])
        print("")
        if let reply = await stream(model: model, messages: messages, think: think) {
            messages.append(["role": "assistant", "content": reply])
        } else {
            messages.removeLast()
        }
        print("")
    }
}

// MARK: Entry

var args = Array(CommandLine.arguments.dropFirst())
let think = parseThink(&args)
let command = args.first ?? "chat"

let done = DispatchSemaphore(value: 0)
Task {
    switch command {
    case "help", "-h", "--help":
        usage()
    case "status":
        print(await serverUp() ? "Synapse is running at \(base)" : "Synapse isn't running.")
    case "models", "list":
        await ensureServer()
        for m in await listModels() { print("\(m.id)\(m.name != m.id && !m.id.hasSuffix(m.name) ? "  \(dim)\(m.name)\(reset)" : "")") }
    case "run":
        await ensureServer()
        guard args.count >= 2 else { usage(); break }
        var prompt = args.dropFirst(2).joined(separator: " ")
        if prompt.isEmpty, let data = try? FileHandle.standardInput.readToEnd() { prompt = String(decoding: data, as: UTF8.self) }
        _ = await stream(model: args[1], messages: [["role": "user", "content": prompt]], think: think)
    case "chat":
        await ensureServer()
        await chat(model: args.count > 1 ? args[1] : nil, think: think)
    default:
        // `synapse <model>` shortcut
        await ensureServer()
        await chat(model: command, think: think)
    }
    done.signal()
}
done.wait()
