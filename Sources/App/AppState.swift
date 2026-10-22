import Foundation
import SwiftUI
import Observation

enum SidebarItem: Hashable {
    case chat(UUID)
    case project(UUID)
    case models
    case sites
    case usage
}

struct ApprovalRequest: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    var diff: FileDiff? = nil
    let continuation: CheckedContinuation<Bool, Never>
}

private struct SavedState: Codable {
    var chats: [Chat]
    var projects: [Project]
    var localModels: [LocalModel]
}

@MainActor
@Observable
final class AppState {
    // Data
    var chats: [Chat] = []
    var projects: [Project] = []
    var localModels: [LocalModel] = []
    var remoteModels: [ProviderID: [ModelRef]] = [:]
    var remoteErrors: [ProviderID: String] = [:]

    // UI
    var selection: SidebarItem?
    var showKeys = false
    var showBrowserPanel = false
    var approvals: [ApprovalRequest] = []
    var generating: Set<UUID> = []
    var keysVersion = 0   // bump to refresh views that read the keychain
    var modelHealth: [String: ModelHealthRecord] = ModelHealthRecord.load()
    var dismissedWarnings: Set<String> = []

    // Services
    let engine = LocalEngine()
    let downloads = DownloadManager()
    let browser = BrowserController()
    let sites = SiteManager()
    let usage = UsageTracker()
    let settings = AppSettings.shared
    let controlOverlay = ControlOverlay()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var apiServer: HTTPServer?

    init() {
        load()
        controlOverlay.onStop = { [weak self] id in self?.stop(id) }
        downloads.onComplete = { [weak self] model in
            guard let self else { return }
            self.localModels.removeAll { $0.id == model.id }
            self.localModels.append(model)
            self.save()
        }
        if let first = chats.sorted(by: { $0.updatedAt > $1.updatedAt }).first { selection = .chat(first.id) } else { newChat() }
        Task { await refreshRemoteModels() }
        startAPIServer()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        chats = s.chats
        projects = s.projects
        localModels = s.localModels.filter { FileManager.default.fileExists(atPath: $0.directory) }
    }

    func save() {
        let s = SavedState(chats: chats, projects: projects, localModels: localModels)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Paths.stateFile, options: .atomic) }
    }

    // MARK: Models

    var allModels: [ModelRef] {
        localModels.map(\.ref) + ProviderID.allCases.flatMap { remoteModels[$0] ?? [] }
    }

    func hasKey(_ p: ProviderID) -> Bool { _ = keysVersion; return Keychain.get(p.rawValue) != nil }

    func setKey(_ key: String?, for p: ProviderID) {
        Keychain.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: p.rawValue)
        keysVersion += 1
        Task { await refreshRemoteModels(only: p) }
    }

    func refreshRemoteModels(only: ProviderID? = nil) async {
        let providers = only.map { [$0] } ?? [.google, .groq, .anthropic, .deepseek, .openrouter, .custom]
        await withTaskGroup(of: (ProviderID, Result<[ModelRef], Error>?).self) { group in
            for p in providers {
                let enabled = p == .custom ? settings.customEnabled : Keychain.get(p.rawValue) != nil
                group.addTask {
                    guard enabled else { return (p, nil) }
                    do { return (p, .success(try await ChatClient.listModels(provider: p))) }
                    catch { return (p, .failure(error)) }
                }
            }
            for await (p, result) in group {
                switch result {
                case .none: remoteModels[p] = nil; remoteErrors[p] = nil
                case .success(let list):
                    remoteModels[p] = list; remoteErrors[p] = nil
                    if p == .google { Task { await probeGoogleModels(list) } }
                case .failure(let e): remoteErrors[p] = e.localizedDescription
                }
            }
        }
    }

    func localModel(_ id: String) -> LocalModel? { localModels.first { $0.id == id } }

    func loadLocal(_ m: LocalModel) async throws {
        try await engine.ensureLoaded(m, contextSize: settings.contextSize)
    }

    func deleteLocalModel(_ m: LocalModel) {
        if engine.loadedModelID == m.id { engine.stop() }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: m.directory), resultingItemURL: nil)
        localModels.removeAll { $0.id == m.id }
        save()
    }

    /// Picks a sensible model for new chats.
    var defaultModel: ModelRef? {
        if let d = settings.defaultModel {
            if d.provider == .local { if localModel(d.id) != nil { return d } }
            else if hasKey(d.provider), isUsable(d), health(d) != .busy { return d }
        }
        let firstUsable: (ProviderID) -> ModelRef? = { p in self.remoteModels[p]?.first { self.isUsable($0) && self.health($0) != .busy } }
        return firstUsable(.google) ?? firstUsable(.groq) ?? firstUsable(.anthropic) ?? firstUsable(.deepseek) ?? localModels.first?.ref
    }

    // MARK: Model health (which listed models actually work on this key)

    func health(_ m: ModelRef) -> ModelHealth? { modelHealth[m.qualifiedID]?.health }

    /// Hides models the provider lists but won't serve on this key (retired, or not on the free tier).
    func isUsable(_ m: ModelRef) -> Bool {
        if case .unavailable = health(m) { return false }
        return true
    }

    func setModelHealth(_ m: ModelRef, _ h: ModelHealth) {
        modelHealth[m.qualifiedID] = ModelHealthRecord(health: h, checked: Date())
        ModelHealthRecord.save(modelHealth)
    }

    /// Google models to try, in order, when the chosen one is busy or unavailable.
    var googleFallbackChain: [String] {
        let preferred = ["gemini-3.5-flash", "gemini-3.6-flash", "gemini-3-flash-preview", "gemini-3.5-flash-lite",
                         "gemini-3.1-flash-lite", "gemini-flash-lite-latest", "gemma-4-26b-a4b-it", "gemma-4-31b-it"]
        let list = remoteModels[.google] ?? []
        let usable = preferred.filter { id in list.first(where: { $0.id == id }).map(isUsable) ?? false }
        // Models not marked busy first, busy ones last (Google's "busy" often clears within minutes).
        let notBusy = usable.filter { id in list.first { $0.id == id }.map { health($0) != .busy } ?? true }
        let chain = notBusy + usable.filter { !notBusy.contains($0) }
        return chain.isEmpty ? ["gemini-flash-lite-latest"] : chain
    }

    /// The Google model to answer with when the chosen one is busy or unavailable.
    var googleFallbackModel: String {
        let preferred = ["gemini-3.5-flash", "gemini-3.6-flash", "gemini-3-flash-preview", "gemini-3.5-flash-lite",
                         "gemini-3.1-flash-lite", "gemini-flash-lite-latest"]
        let list = remoteModels[.google] ?? []
        for id in preferred {
            if let m = list.first(where: { $0.id == id }), isUsable(m), health(m) != .busy { return id }
        }
        return "gemini-flash-lite-latest"
    }

    /// Once a day, send a tiny request to each Google model so the picker only offers ones that work.
    func probeGoogleModels(_ list: [ModelRef]) async {
        let stale = list.filter { m in
            guard let r = modelHealth[m.qualifiedID] else { return true }
            return Date().timeIntervalSince(r.checked) > (r.health == .ok ? 86_400 : r.health == .busy ? 1_800 : 7 * 86_400)
        }
        guard !stale.isEmpty else { return }
        await withTaskGroup(of: (ModelRef, ModelHealth?).self) { group in
            for m in stale {
                group.addTask {
                    let body: [String: Any] = ["model": m.id, "max_tokens": 16, "messages": [["role": "user", "content": "Reply with OK."]]]
                    guard var req = try? ChatClient.makeRequest(provider: .google, path: "/chat/completions", body: body) else { return (m, nil) }
                    req.timeoutInterval = 25
                    guard let (data, resp) = try? await URLSession.shared.data(for: req),
                          let code = (resp as? HTTPURLResponse)?.statusCode else { return (m, .busy) }
                    let message = ChatClient.errorMessage(from: data)
                    switch code {
                    case 200..<300: return (m, .ok)
                    case 404: return (m, .unavailable("Retired for new keys"))
                    case 429 where message.contains("limit: 0"): return (m, .unavailable("Not on the free tier"))
                    case 429: return (m, .ok)            // works, just rate limited right now
                    case 503, 500, 502, 504: return (m, .busy)
                    default: return (m, nil)
                    }
                }
            }
            for await (m, h) in group { if let h { setModelHealth(m, h) } }
        }
    }

    // MARK: Usage warnings

    /// A short warning when a provider's limits are running low (shown above the composer).
    func usageWarning(for p: ProviderID) -> String? {
        guard p != .local else { return nil }
        let u = usage.usage(p)
        if let at = u.lastLimitErrorAt, Date().timeIntervalSince(at) < 15 * 60 {
            return "You hit \(p.displayName)'s rate limit \(at.formatted(.relative(presentation: .named))). Wait a bit or switch models."
        }
        if let rl = u.rateLimit, Date().timeIntervalSince(rl.updatedAt) < 3_600, let f = rl.lowestRemainingFraction, f < 0.15 {
            var parts: [String] = []
            if let r = rl.remainingRequests, let l = rl.limitRequests { parts.append("\(r) of \(l) requests left") }
            if let r = rl.remainingTokens, let l = rl.limitTokens, Double(r) / Double(max(l, 1)) < 0.15 { parts.append("\(r.formatted()) tokens left") }
            let reset = rl.resetRequests ?? rl.resetTokens
            return "\(p.displayName) is running low: " + parts.joined(separator: ", ") + (reset.map { " · resets in \($0)" } ?? "")
        }
        return nil
    }

    // MARK: Chats & projects

    func chatIndex(_ id: UUID) -> Int? { chats.firstIndex { $0.id == id } }

    @discardableResult
    func newChat(project: UUID? = nil) -> UUID {
        // Reuse an untouched empty chat instead of piling up blank ones.
        if let empty = chats.first(where: { $0.messages.isEmpty && $0.projectID == project && !generating.contains($0.id) }) {
            selection = .chat(empty.id)
            return empty.id
        }
        var c = Chat()
        c.projectID = project
        c.model = defaultModel
        if let last = chats.max(by: { $0.updatedAt < $1.updatedAt }) {
            c.capabilities = last.capabilities
            c.think = last.think
        }
        chats.append(c)
        selection = .chat(c.id)
        save()
        return c.id
    }

    func deleteChat(_ id: UUID) {
        stop(id)
        chats.removeAll { $0.id == id }
        if selection == .chat(id) { selection = chats.max(by: { $0.updatedAt < $1.updatedAt }).map { .chat($0.id) } }
        save()
    }

    @discardableResult
    func newProject(name: String, folder: URL? = nil) -> UUID {
        let dir = folder ?? Paths.projectsRoot.appendingPathComponent(SiteManager.slug(name).ifEmpty("project"), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Project(name: name, folder: dir.path)
        projects.append(p)
        selection = .project(p.id)
        save()
        return p.id
    }

    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for i in chats.indices where chats[i].projectID == id { chats[i].projectID = nil }
        if selection == .project(id) { selection = nil }
        save()
    }

    func project(for chat: Chat) -> Project? { chat.projectID.flatMap { id in projects.first { $0.id == id } } }

    // MARK: Generation

    func send(chatID: UUID, text: String, attachments: [Attachment]) {
        guard let i = chatIndex(chatID), !generating.contains(chatID) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        chats[i].messages.append(ChatMessage(role: .user, content: trimmed, attachments: attachments))
        if chats[i].title == "New Chat" || chats[i].title == "New chat" {
            let words = trimmed.split(separator: " ").prefix(7).joined(separator: " ")
            chats[i].title = words.isEmpty ? (attachments.first?.filename ?? "New Chat") : String(words.prefix(60))
        }
        chats[i].updatedAt = Date()
        save()
        run(chatID)
    }

    func regenerate(chatID: UUID) {
        guard let i = chatIndex(chatID), !generating.contains(chatID) else { return }
        while let last = chats[i].messages.last, last.role != .user { chats[i].messages.removeLast() }
        guard !chats[i].messages.isEmpty else { return }
        run(chatID)
    }

    private func run(_ chatID: UUID) {
        generating.insert(chatID)
        tasks[chatID] = Task {
            await Agent(app: self, chatID: chatID).run()
            browser.agentActive = false
            controlOverlay.hide(chatID: chatID)
            generating.remove(chatID)
            tasks[chatID] = nil
            save()
        }
    }

    func stop(_ chatID: UUID) {
        controlOverlay.hide(chatID: chatID)
        tasks[chatID]?.cancel()
        tasks[chatID] = nil
        generating.remove(chatID)
        // Release any approval prompts that belong to the cancelled run.
        let pending = approvals
        approvals.removeAll()
        pending.forEach { $0.continuation.resume(returning: false) }
    }

    func requestApproval(title: String, detail: String, diff: FileDiff? = nil) async -> Bool {
        await withCheckedContinuation { c in
            approvals.append(ApprovalRequest(title: title, detail: detail, diff: diff, continuation: c))
        }
    }

    func resolveApproval(_ id: UUID, _ ok: Bool) {
        guard let i = approvals.firstIndex(where: { $0.id == id }) else { return }
        let a = approvals.remove(at: i)
        a.continuation.resume(returning: ok)
    }

    // MARK: Attachments

    func makeAttachment(from url: URL) -> Attachment? {
        let ext = url.pathExtension.lowercased()
        let dest = Paths.attachments.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return nil }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) {
            return Attachment(kind: .image, filename: url.lastPathComponent, path: dest.path)
        }
        let text = Tools.readText(dest)
        return Attachment(kind: ext == "pdf" ? .pdf : .text, filename: url.lastPathComponent, path: dest.path, extractedText: text.truncated(120_000))
    }

    func attachImage(_ image: NSImage) -> Attachment? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dest = Paths.attachments.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
        try? png.write(to: dest)
        return Attachment(kind: .image, filename: "Pasted image", path: dest.path)
    }

    // MARK: Local OpenAI-compatible API (used by the `synapse` CLI and other apps)

    func startAPIServer() {
        apiServer?.stop()
        apiServer = nil
        guard settings.apiServerEnabled else { return }
        let server = HTTPServer(port: settings.apiServerPort) { [weak self] req, res in
            await self?.handleAPI(req, res)
        }
        try? server.start()
        apiServer = server
    }

    nonisolated func handleAPI(_ req: HTTPRequest, _ res: HTTPResponder) async {
        if req.method == "OPTIONS" {
            res.send(status: 204, headers: ["Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "GET, POST, OPTIONS"], body: Data())
            return
        }
        switch (req.method, req.path) {
        case ("GET", "/health"), ("GET", "/"):
            res.sendJSON(["status": "ok", "app": "Synapse"])
        case ("GET", "/v1/models"):
            let models = await MainActor.run { self.allModels }
            res.sendJSON(["object": "list", "data": models.map { ["id": $0.qualifiedID, "object": "model", "owned_by": $0.provider.rawValue, "name": $0.name] }])
        case ("POST", "/v1/chat/completions"):
            await proxyChat(req, res)
        default:
            res.sendJSON(status: 404, ["error": ["message": "Not found: \(req.method) \(req.path)"]])
        }
    }

    nonisolated private func proxyChat(_ req: HTTPRequest, _ res: HTTPResponder) async {
        guard var body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            res.sendJSON(status: 400, ["error": ["message": "Invalid JSON"]]); return
        }
        let requested = body["model"] as? String ?? ""
        let resolved: (ProviderID, String)? = await MainActor.run {
            let all = self.allModels
            let ref = all.first { $0.qualifiedID == requested } ?? all.first { $0.id == requested || $0.name == requested } ?? self.defaultModel
            guard let ref else { return nil }
            return (ref.provider, ref.id)
        }
        guard let (provider, modelID) = resolved else {
            res.sendJSON(status: 400, ["error": ["message": "Unknown model \(requested). GET /v1/models lists available models."]]); return
        }
        do {
            if provider == .local {
                guard let m = await MainActor.run(body: { self.localModel(modelID) }) else {
                    throw APIError(status: 0, message: "Model not found")
                }
                try await self.loadLocal(m)
                body["model"] = await MainActor.run { self.engine.requestModelName(for: m) }
            } else {
                body["model"] = modelID
            }
            if let think = body.removeValue(forKey: "synapse_think") as? String, let level = ThinkLevel(rawValue: think) {
                let extra = await MainActor.run { Agent.thinkingParams(provider: provider, model: modelID, level: level) }
                body.merge(extra) { $1 }
            }
            await MainActor.run { self.usage.recordRequest(provider, model: modelID) }
            let urlReq = try ChatClient.makeRequest(provider: provider, path: "/chat/completions", body: body)
            let (bytes, resp) = try await URLSession.shared.bytes(for: urlReq)
            let http = resp as? HTTPURLResponse
            if let http, let rl = RateLimitInfo(headers: http.allHeaderFields) {
                await MainActor.run { self.usage.recordRateLimit(provider, rl) }
            }
            res.beginStream(status: http?.statusCode ?? 200, contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json")
            var chunk = Data()
            for try await b in bytes {
                chunk.append(b)
                if b == 10 || chunk.count >= 4096 { res.write(chunk); chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { res.write(chunk) }
            res.end()
        } catch {
            res.sendJSON(status: 502, ["error": ["message": error.localizedDescription]])
        }
    }

    // MARK: CLI install

    var cliBundlePath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/synapse-cli").path }

    func installCLI() -> String {
        let src = cliBundlePath
        guard FileManager.default.fileExists(atPath: src) else { return "The command-line tool wasn't found inside the app." }
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        for dir in candidates {
            if dir.hasSuffix(".local/bin") { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            guard FileManager.default.isWritableFile(atPath: dir) else { continue }
            let link = dir + "/synapse"
            try? FileManager.default.removeItem(atPath: link)
            do {
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: src)
                return "Installed: \(link)\nTry it: synapse chat"
            } catch { continue }
        }
        return "Couldn't install. Run in Terminal:\nsudo ln -sf \"\(src)\" /usr/local/bin/synapse"
    }
}


enum ModelHealth: Codable, Hashable {
    case ok, busy
    case unavailable(String)
}

struct ModelHealthRecord: Codable {
    var health: ModelHealth
    var checked: Date

    static var file: URL { Paths.support.appendingPathComponent("model-health.json") }
    static func load() -> [String: ModelHealthRecord] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: ModelHealthRecord].self, from: $0) } ?? [:]
    }
    static func save(_ all: [String: ModelHealthRecord]) {
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: file) }
    }
}
