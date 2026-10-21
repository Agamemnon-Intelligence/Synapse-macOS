import Foundation
import AppKit

/// Runs one turn of a chat: streams the reply, executes tool calls, and loops until done.
@MainActor
struct Agent {
    let app: AppState
    let chatID: UUID
    static let maxSteps = 30
    static let googleFallback = "gemini-flash-lite-latest"

    var chat: Chat? { app.chatIndex(chatID).map { app.chats[$0] } }

    func run() async {
        guard let chat, let model = chat.model ?? app.defaultModel else {
            append(ChatMessage(role: .assistant, content: "Pick a model first: add an API key (Accounts, top right) or download a local model in Models.", isError: true))
            return
        }
        if chat.model == nil, let i = app.chatIndex(chatID) { app.chats[i].model = model }

        // Local models need the engine running first.
        var requestModel = model.id
        if model.provider == .local {
            guard let local = app.localModel(model.id) else {
                append(ChatMessage(role: .assistant, content: "That local model was deleted. Pick another model.", isError: true))
                return
            }
            let placeholder = append(ChatMessage(role: .assistant, content: "", modelName: model.name))
            setReasoning(placeholder, "Loading \(local.displayName) into memory…")
            do { try await app.loadLocal(local) } catch {
                update(placeholder) { $0.reasoning = ""; $0.content = error.localizedDescription; $0.isError = true }
                return
            }
            remove(placeholder)
            requestModel = app.engine.requestModelName(for: local)
        }

        let ctx = ToolContext(app: app, chatID: chatID, capabilities: chat.capabilities, project: app.project(for: chat),
                              autoApprove: chat.autoApprove)
        let tools = Tools.definitions(for: ctx)

        for _ in 0..<Self.maxSteps {
            if Task.isCancelled { return }
            guard let current = self.chat else { return }
            let messages = buildMessages(current, model: model, project: ctx.project, tools: !tools.isEmpty)
            let msgID = append(ChatMessage(role: .assistant, modelName: model.name))
            let calls: [ToolCall]
            do {
                calls = try await streamReply(into: msgID, model: model, requestModel: requestModel, messages: messages,
                                              tools: tools, think: current.think)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                update(msgID) { $0.content += ($0.content.isEmpty ? "" : "\n\n") + friendlyError(error, model: model); $0.isError = true }
                return
            }
            if calls.isEmpty {
                if current.think == .max, !Task.isCancelled { await refine(msgID, model: model, requestModel: requestModel, base: messages) }
                return
            }
            update(msgID) { $0.toolCalls = calls }
            for call in calls {
                if Task.isCancelled { return }
                let result = await Tools.run(call, ctx: ctx)
                var m = ChatMessage(role: .tool, content: result.text)
                m.toolCallID = call.id
                m.toolName = call.name
                m.images = result.images
                m.presentedFiles = result.presented
                m.links = result.links
                append(m)
            }
        }
        append(ChatMessage(role: .assistant, content: "Stopped after \(Self.maxSteps) tool steps. Say “continue” to keep going.", isError: true))
    }

    // MARK: Streaming

    private func streamReply(into msgID: UUID, model: ModelRef, requestModel: String, messages: [[String: Any]],
                             tools: [[String: Any]], think: ThinkLevel) async throws -> [ToolCall] {
        var body: [String: Any] = ["model": requestModel, "messages": messages]
        if !tools.isEmpty { body["tools"] = tools }
        let thinkParams = Self.thinkingParams(provider: model.provider, model: model.id, level: think)
        var attempt = body.merging(thinkParams) { $1 }

        for tryNumber in 0..<4 {
            do {
                return try await streamOnce(into: msgID, provider: model.provider, modelID: model.id, body: attempt)
            } catch let e as APIError where e.status == 503 && model.provider == .google
                        && (attempt["model"] as? String) != Self.googleFallback && chatMessage(msgID)?.content.isEmpty != false {
                // Google is overloaded: answer with the lighter model instead of failing.
                attempt["model"] = Self.googleFallback
                update(msgID) { $0.modelName = Self.googleFallback + " (fallback: \(model.name) is busy)" }
                continue
            } catch let e as APIError where e.status == 400 || e.status == 422 {
                // Some models reject reasoning or tool parameters: retry with fewer extras.
                let hadOutput = (chatMessage(msgID)?.content.isEmpty == false)
                if hadOutput || tryNumber == 3 { throw e }
                if tryNumber == 0 && !thinkParams.isEmpty { attempt = body; continue }
                if attempt["tools"] != nil && e.message.lowercased().contains("tool") {
                    attempt["tools"] = nil
                    update(msgID) { $0.reasoning += "(This model doesn't support tools, so capabilities are off for this reply.)\n" }
                    continue
                }
                throw e
            }
        }
        return []
    }

    private func streamOnce(into msgID: UUID, provider: ProviderID, modelID: String, body: [String: Any]) async throws -> [ToolCall] {
        app.usage.recordRequest(provider, model: modelID)
        var calls: [ToolCall] = []
        var pendingContent = "", pendingReasoning = ""
        var lastFlush = Date()
        func flush() {
            guard !pendingContent.isEmpty || !pendingReasoning.isEmpty else { return }
            let c = pendingContent, r = pendingReasoning
            update(msgID) { $0.content += c; $0.reasoning += r }
            pendingContent = ""; pendingReasoning = ""
            lastFlush = Date()
        }
        do {
            for try await event in ChatClient.stream(provider: provider, body: body) {
                try Task.checkCancellation()
                switch event {
                case .content(let s): pendingContent += s
                case .reasoning(let s): pendingReasoning += s
                case .toolCalls(let c): calls = c
                case .usage(let u): app.usage.recordTokens(provider, u)
                case .rateLimit(let r): app.usage.recordRateLimit(provider, r)
                }
                if Date().timeIntervalSince(lastFlush) > 0.05 { flush() }
            }
        } catch {
            flush()
            if let e = error as? APIError, e.status == 429 { app.usage.recordLimitError(provider, e.message) }
            throw error
        }
        flush()
        // Strip leading whitespace some models emit after thinking.
        update(msgID) { $0.content = $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
        return calls
    }

    /// "Think harder": a second pass that critiques and rewrites the draft.
    private func refine(_ msgID: UUID, model: ModelRef, requestModel: String, base: [[String: Any]]) async {
        guard let draft = chatMessage(msgID)?.content, !draft.isEmpty else { return }
        var messages = base
        messages.append(["role": "assistant", "content": draft])
        messages.append(["role": "user", "content": """
            Review your previous answer like a strict expert. Check every fact, calculation, step and piece of code for errors, \
            gaps and anything you misread in my request. Then write the corrected, complete final answer. \
            Reply with ONLY the final answer, no commentary about the review.
            """])
        update(msgID) {
            $0.reasoning += ($0.reasoning.isEmpty ? "" : "\n\n") + "── First draft ──\n" + draft + "\n\n── Reviewing and refining ──\n"
            $0.content = ""
        }
        var body: [String: Any] = ["model": requestModel, "messages": messages]
        body.merge(Self.thinkingParams(provider: model.provider, model: model.id, level: .high)) { $1 }
        do {
            _ = try await streamOnce(into: msgID, provider: model.provider, modelID: model.id, body: body)
        } catch {
            if (chatMessage(msgID)?.content ?? "").isEmpty { update(msgID) { $0.content = draft } }
        }
    }

    /// Provider-specific knobs that make a model reason more (or less).
    static func thinkingParams(provider: ProviderID, model: String, level: ThinkLevel) -> [String: Any] {
        let m = model.lowercased()
        switch provider {
        case .google:
            var cfg: [String: Any] = ["include_thoughts": level != .off]
            if m.contains("2.5") {
                cfg["thinking_budget"] = level == .off ? (m.contains("pro") ? 128 : 0) : level == .standard ? -1 : 24_576
            } else if level != .standard {
                cfg["thinking_level"] = level == .off ? "low" : "high"
            }
            return ["extra_body": ["google": ["thinking_config": cfg]]]
        case .groq:
            if m.contains("gpt-oss") {
                let effort = level == .off ? "low" : level == .standard ? "medium" : "high"
                return ["reasoning_effort": effort, "include_reasoning": true]
            }
            if m.contains("qwen3") || m.contains("qwen-3") {
                let effort = level == .off ? "none" : "default"
                return ["reasoning_effort": effort, "reasoning_format": "parsed"]
            }
            return [:]
        case .openrouter:
            if level == .standard { return [:] }
            let effort: [String: Any] = ["effort": level == .off ? "low" : "high"]
            return ["reasoning": effort]
        case .local:
            let effort = level == .off ? "low" : level == .standard ? "medium" : "high"
            let kwargs: [String: Any] = ["enable_thinking": level != .off, "reasoning_effort": effort]
            return ["chat_template_kwargs": kwargs]
        case .custom:
            if level == .standard { return [:] }
            let effort = level == .off ? "low" : "high"
            return ["reasoning_effort": effort]
        }
    }

    // MARK: Prompt building

    private func systemPrompt(_ chat: Chat, project: Project?, tools: Bool) -> String {
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short
        var s = """
        You are a helpful AI assistant running inside Synapse, a Mac app. Today is \(df.string(from: Date())). \
        The user is on macOS (\(HardwareInfo.current.chip)). Use Markdown. Use fenced code blocks with a language tag for code.
        """
        let caps = chat.capabilities
        if tools {
            var lines: [String] = []
            if caps.webSearch { lines.append("- Search the web and read pages. Do this for anything recent or uncertain, and cite source URLs.") }
            if caps.imageGeneration { lines.append("- Generate images with generate_image when the user asks for a picture.") }
            if caps.computerAccess { lines.append("- Use the user's Mac: shell commands, files, AppleScript, opening apps, screenshots. The user approves risky actions. Prefer safe, reversible commands; never delete user data unless explicitly asked.") }
            if caps.browser { lines.append("- Drive the built-in browser: browser_navigate, then browser_click / browser_type using element numbers from the latest page read. Never enter passwords or payment details; ask the user to do that.") }
            if caps.websites { lines.append("- Build websites with create_website. Write complete, polished, responsive HTML/CSS/JS; the site is hosted on localhost and opened for the user.") }
            if project != nil || caps.computerAccess { lines.append("- Read, write and present files. Use present_file to show finished documents to the user.") }
            if !lines.isEmpty { s += "\n\nYou can:\n" + lines.joined(separator: "\n") + "\nUse tools when they help; don't narrate tool calls at length." }
        }
        switch chat.think {
        case .off: s += "\n\nAnswer directly and concisely."
        case .standard: break
        case .high, .max:
            s += "\n\nThis task deserves careful thought. Before answering, reason step by step: restate the goal, consider several approaches, work through details, check edge cases, and verify your result. Prefer correctness over speed."
        }
        if let project {
            s += "\n\n# Project: \(project.name)\nProject folder: \(project.folder)"
            if !project.instructions.isEmpty { s += "\n\nProject instructions:\n\(project.instructions)" }
            let files = ProjectFiles.list(project).prefix(200)
            if !files.isEmpty {
                s += "\n\nFiles in the project (relative paths):\n" + files.map { "- " + $0 }.joined(separator: "\n")
                s += "\n\nUse read_file to open them."
            }
        }
        if !app.settings.systemPrompt.isEmpty { s += "\n\n" + app.settings.systemPrompt }
        return s
    }

    private func buildMessages(_ chat: Chat, model: ModelRef, project: Project?, tools: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": systemPrompt(chat, project: project, tools: tools)]]
        let vision = model.vision || model.provider == .google || model.provider == .custom
        var pendingImages: [String] = []

        func imagePart(_ path: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            var bytes = data, mime = "image/png"
            if let img = NSImage(data: data), data.count > 3_500_000, let jpeg = Self.downscaledJPEG(img) { bytes = jpeg; mime = "image/jpeg" }
            else if ["jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased()) { mime = "image/jpeg" }
            return ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(bytes.base64EncodedString())"]]
        }
        func flushImages() {
            guard !pendingImages.isEmpty else { return }
            if vision {
                var parts: [[String: Any]] = [["type": "text", "text": "(Images returned by the tools above.)"]]
                parts += pendingImages.compactMap(imagePart)
                out.append(["role": "user", "content": parts])
            }
            pendingImages = []
        }

        let msgs = chat.messages.filter { !$0.isError }
        for m in msgs {
            switch m.role {
            case .system: continue
            case .user:
                flushImages()
                var text = m.content
                for a in m.attachments where a.kind != .image {
                    text += "\n\n<file name=\"\(a.filename)\">\n\(a.extractedText ?? "")\n</file>"
                }
                let images = m.attachments.filter { $0.kind == .image }
                if images.isEmpty || !vision {
                    if !images.isEmpty { text += "\n\n(The user attached \(images.count) image(s), but this model can't see images.)" }
                    out.append(["role": "user", "content": text])
                } else {
                    var parts: [[String: Any]] = [["type": "text", "text": text.isEmpty ? "See the attached image." : text]]
                    parts += images.compactMap { imagePart($0.path) }
                    out.append(["role": "user", "content": parts])
                }
            case .assistant:
                flushImages()
                var a: [String: Any] = ["role": "assistant", "content": m.content]
                if !m.toolCalls.isEmpty {
                    a["tool_calls"] = m.toolCalls.map { c -> [String: Any] in
                        var d: [String: Any] = ["id": c.id, "type": "function", "function": ["name": c.name, "arguments": c.arguments.isEmpty ? "{}" : c.arguments]]
                        if let extra = c.extra { d["extra_content"] = extra.any }
                        return d
                    }
                    if m.content.isEmpty { a["content"] = NSNull() }
                } else if m.content.isEmpty { continue }
                out.append(a)
            case .tool:
                out.append(["role": "tool", "tool_call_id": m.toolCallID ?? "", "content": m.content])
                // Only screenshots go back to the model; generated images are just shown to the user.
                if m.toolName == "take_screenshot" || m.toolName == "browser_screenshot" || m.toolName == "present_file" {
                    pendingImages += m.images
                }
            }
        }
        flushImages()
        // Drop tool messages whose assistant call was removed (keeps APIs happy).
        return out
    }

    static func downscaledJPEG(_ img: NSImage, maxSide: CGFloat = 1600) -> Data? {
        let s = img.size
        let scale = min(1, maxSide / max(s.width, s.height))
        let target = NSSize(width: s.width * scale, height: s.height * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: target))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private func friendlyError(_ error: Error, model: ModelRef) -> String {
        guard let e = error as? APIError else { return "⚠️ " + error.localizedDescription }
        switch e.status {
        case 401, 403: return "⚠️ \(model.provider.displayName) rejected the API key. Open Accounts (top right) to fix it.\n\n\(e.message)"
        case 429: return "⚠️ Rate limit reached for \(model.name). Wait a bit, or switch models. See Usage for details.\n\n\(e.message)"
        case 404: return "⚠️ Model not available: \(model.name).\n\n\(e.message)"
        case 503: return "⚠️ \(model.provider.displayName) is overloaded right now. Try again or switch models.\n\n\(e.message)"
        default: return "⚠️ " + (e.errorDescription ?? e.message)
        }
    }

    // MARK: Message mutation

    @discardableResult
    private func append(_ m: ChatMessage) -> UUID {
        guard let i = app.chatIndex(chatID) else { return m.id }
        app.chats[i].messages.append(m)
        app.chats[i].updatedAt = Date()
        return m.id
    }

    private func update(_ id: UUID, _ f: (inout ChatMessage) -> Void) {
        guard let i = app.chatIndex(chatID), let j = app.chats[i].messages.firstIndex(where: { $0.id == id }) else { return }
        f(&app.chats[i].messages[j])
    }

    private func setReasoning(_ id: UUID, _ s: String) { update(id) { $0.reasoning = s } }

    private func remove(_ id: UUID) {
        guard let i = app.chatIndex(chatID) else { return }
        app.chats[i].messages.removeAll { $0.id == id }
    }

    private func chatMessage(_ id: UUID) -> ChatMessage? {
        app.chatIndex(chatID).flatMap { i in app.chats[i].messages.first { $0.id == id } }
    }
}

enum ProjectFiles {
    static func list(_ p: Project, limit: Int = 500) -> [String] {
        let root = p.folderURL
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let url as URL in e {
            let name = url.lastPathComponent
            if ["node_modules", ".git", "build", "DerivedData", ".venv", "venv", "__pycache__"].contains(name) { e.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            out.append(String(url.path.dropFirst(root.path.count + 1)))
            if out.count >= limit { break }
        }
        return out.sorted()
    }
}
