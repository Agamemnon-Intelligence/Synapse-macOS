import Foundation
import AppKit
import PDFKit

struct ToolResult {
    var text: String
    var images: [String] = []
    var presented: [String] = []
    var links: [String] = []
    var diff: FileDiff? = nil
}

@MainActor
struct ToolContext {
    let app: AppState
    let chatID: UUID
    let capabilities: Capabilities
    let project: Project?
    let autoApprove: Bool

    var workDir: URL { project?.folderURL ?? URL(fileURLWithPath: NSHomeDirectory()) }
    var filesEnabled: Bool { project != nil || capabilities.computerAccess }
}

@MainActor
enum Tools {
    // MARK: Definitions

    static func definitions(for ctx: ToolContext) -> [[String: Any]] {
        var defs: [[String: Any]] = []
        func add(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = []) {
            defs.append(["type": "function", "function": [
                "name": name, "description": desc,
                "parameters": ["type": "object", "properties": props, "required": required] as [String: Any],
            ] as [String: Any]])
        }
        let str: (String) -> [String: Any] = { ["type": "string", "description": $0] }

        if ctx.capabilities.webSearch {
            add("web_search", "Search the web. Returns titles, URLs and snippets. Use for current events or facts you aren't sure about.",
                ["query": str("Search query")], required: ["query"])
            add("fetch_url", "Download a web page and return its readable text.", ["url": str("Full URL")], required: ["url"])
        }
        if ctx.capabilities.imageGeneration {
            add("generate_image", "Create an image from a text description. The image is shown to the user automatically.",
                ["prompt": str("Detailed description of the image"),
                 "aspect": ["type": "string", "enum": ["square", "landscape", "portrait"], "description": "Aspect ratio"] as [String: Any]],
                required: ["prompt"])
        }
        add("create_presentation", "Create a PowerPoint (.pptx) slide deck and show it to the user as an attachment they can present. Keep slides short: 3-6 bullets each.",
            ["title": str("Deck title (also the title slide)"),
             "subtitle": str("Optional subtitle for the title slide"),
             "theme": ["type": "string", "enum": ["dark", "light", "warm"], "description": "Visual style"] as [String: Any],
             "slides": ["type": "array", "description": "Content slides after the title slide",
                        "items": ["type": "object",
                                  "properties": ["title": str("Slide title"),
                                                 "bullets": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any]],
                                  "required": ["title", "bullets"]] as [String: Any]] as [String: Any]],
            required: ["title", "slides"])
        if ctx.filesEnabled {
            let scope = ctx.capabilities.computerAccess ? "Paths may be absolute or relative to the working folder."
                                                        : "Paths are relative to the project folder."
            add("list_files", "List files and folders. " + scope, ["path": str("Folder path, default is the working folder")])
            add("read_file", "Read a text, code or PDF file. " + scope, ["path": str("File path")], required: ["path"])
            add("write_file", "Create or overwrite a text file. " + scope, ["path": str("File path"), "content": str("Full file contents")], required: ["path", "content"])
            add("edit_file", "Change part of an existing text file by replacing old_text with new_text (old_text must match exactly, including whitespace). Prefer this over rewriting a whole file. " + scope,
                ["path": str("File path"), "old_text": str("Exact text to replace (unique in the file)"), "new_text": str("Replacement text"),
                 "replace_all": ["type": "boolean", "description": "Replace every occurrence"] as [String: Any]],
                required: ["path", "old_text", "new_text"])
            add("present_file", "Show a file to the user as a preview card (documents, images, code, etc).", ["path": str("File path")], required: ["path"])
        }
        if ctx.capabilities.computerAccess {
            add("run_shell", "Run a zsh command on the user's Mac and return its output. The user approves each command.",
                ["command": str("Shell command"), "cwd": str("Working directory (optional)")], required: ["command"])
            add("run_applescript", "Run AppleScript to control Mac apps (e.g. Finder, Music, Mail, System Events).",
                ["script": str("AppleScript source")], required: ["script"])
            add("open", "Open an app, file, folder or URL with the default handler (like the `open` command).",
                ["target": str("App name (e.g. 'Safari'), path or URL")], required: ["target"])
            add("take_screenshot", "Take a screenshot of the user's screen so you can see it.")
        }
        if ctx.capabilities.browser {
            add("browser_navigate", "Open a URL (or search terms) in Synapse's built-in browser. Returns the page text and numbered interactive elements.",
                ["url": str("URL or search terms")], required: ["url"])
            add("browser_read", "Re-read the current browser page, with numbered interactive elements.")
            add("browser_click", "Click a numbered element from the last browser_read.", ["element": ["type": "integer"] as [String: Any]], required: ["element"])
            add("browser_type", "Type text into a numbered input element. Set submit=true to press Enter.",
                ["element": ["type": "integer"] as [String: Any], "text": str("Text to type"), "submit": ["type": "boolean"] as [String: Any]],
                required: ["element", "text"])
            add("browser_scroll", "Scroll the page.", ["direction": ["type": "string", "enum": ["up", "down"]] as [String: Any]], required: ["direction"])
            add("browser_back", "Go back to the previous page.")
            add("browser_screenshot", "Capture the browser so you can see the page visually.")
        }
        if ctx.capabilities.websites {
            add("create_website", "Build a website and host it on localhost. Provide every file (HTML, CSS, JS). Returns the local URL, which opens in the browser.",
                ["name": str("Short site name"),
                 "files": ["type": "array", "description": "Files to write; include index.html",
                           "items": ["type": "object", "properties": ["path": str("Relative path, e.g. index.html"), "content": str("File contents")],
                                     "required": ["path", "content"]] as [String: Any]] as [String: Any]],
                required: ["name", "files"])
        }
        return defs
    }

    // MARK: Execution

    static func run(_ call: ToolCall, ctx: ToolContext) async -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
        func s(_ k: String) -> String { (args[k] as? String) ?? (args[k].map { "\($0)" } ?? "") }
        func i(_ k: String) -> Int { (args[k] as? Int) ?? Int(s(k)) ?? -1 }

        switch call.name {
        case "web_search": return await webSearch(s("query"))
        case "create_presentation":
            let title = s("title").ifEmpty("Presentation")
            let slides = (args["slides"] as? [[String: Any]] ?? []).map {
                PresentationWriter.Slide(title: $0["title"] as? String ?? "", bullets: ($0["bullets"] as? [Any] ?? []).map { "\($0)" })
            }
            guard !slides.isEmpty else { return ToolResult(text: "Add at least one slide.") }
            let theme: PresentationWriter.Theme = s("theme") == "light" ? .light : s("theme") == "warm" ? .warm : .dark
            let folder = ctx.project?.folderURL ?? Paths.files
            var url = folder.appendingPathComponent(SiteManager.slug(title).ifEmpty("presentation") + ".pptx")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent(SiteManager.slug(title) + "-\(n).pptx"); n += 1
            }
            do {
                let subtitle = s("subtitle").isEmpty ? nil : s("subtitle")
                try await Task.detached { try PresentationWriter.write(title: title, subtitle: subtitle, slides: slides, theme: theme, to: url) }.value
                return ToolResult(text: "Created \(url.lastPathComponent) with \(slides.count + 1) slides at \(url.path). It's shown to the user.", presented: [url.path])
            } catch { return ToolResult(text: "Error: \(error.localizedDescription)") }
        case "fetch_url": return await fetchURL(s("url"))
        case "generate_image": return await ImageGen.generate(prompt: s("prompt"), aspect: s("aspect"))

        case "list_files":
            guard let url = resolve(s("path").ifEmpty("."), ctx: ctx) else { return denied() }
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
            let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(300).map { u -> String in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return (v?.isDirectory == true ? "📁 " : "📄 ") + u.lastPathComponent + (v?.isDirectory == true ? "/" : "  (\(formatBytes(Int64(v?.fileSize ?? 0))))")
            }
            return ToolResult(text: "\(url.path)\n" + (lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")))

        case "read_file":
            guard let url = resolve(s("path"), ctx: ctx) else { return denied() }
            return ToolResult(text: readText(url).truncated(60_000))

        case "write_file":
            guard let url = resolve(s("path"), ctx: ctx) else { return denied() }
            let old = try? String(contentsOf: url, encoding: .utf8)
            return await applyChange(url: url, old: old, new: s("content"), ctx: ctx)

        case "edit_file":
            guard let url = resolve(s("path"), ctx: ctx) else { return denied() }
            guard let old = try? String(contentsOf: url, encoding: .utf8) else { return ToolResult(text: "Error: \(url.path) doesn't exist or isn't text. Use write_file to create it.") }
            let find = s("old_text"), replace = s("new_text")
            guard !find.isEmpty else { return ToolResult(text: "Error: old_text is empty.") }
            let count = old.components(separatedBy: find).count - 1
            if count == 0 { return ToolResult(text: "Error: old_text wasn't found in \(url.lastPathComponent). Read the file again and copy the text exactly.") }
            let all = args["replace_all"] as? Bool ?? false
            if count > 1 && !all { return ToolResult(text: "Error: old_text appears \(count) times. Include more surrounding lines so it's unique, or set replace_all.") }
            let new: String
            if all { new = old.replacingOccurrences(of: find, with: replace) }
            else if let r = old.range(of: find) { new = old.replacingCharacters(in: r, with: replace) } else { new = old }
            return await applyChange(url: url, old: old, new: new, ctx: ctx)

        case "present_file":
            guard let url = resolve(s("path"), ctx: ctx) else { return denied() }
            guard FileManager.default.fileExists(atPath: url.path) else { return ToolResult(text: "File not found: \(url.path)") }
            let isImage = ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(url.pathExtension.lowercased())
            return ToolResult(text: "Shown to the user.", images: isImage ? [url.path] : [], presented: isImage ? [] : [url.path])

        case "run_shell":
            let cmd = s("command")
            let cwd = resolve(s("cwd").ifEmpty("."), ctx: ctx) ?? ctx.workDir
            guard await approve(ctx, "Run command", "In \(cwd.path):\n\n\(cmd)") else { return declined() }
            let timeout = AppSettings.shared.shellTimeout
            let r = await Task.detached { runProcess("/bin/zsh", ["-lc", cmd], cwd: cwd, timeout: timeout) }.value
            return ToolResult(text: "exit \(r.status)\n" + r.output.truncated(30_000))

        case "run_applescript":
            let script = s("script")
            guard await approve(ctx, "Control apps with AppleScript", script) else { return declined() }
            let r = await Task.detached { runProcess("/usr/bin/osascript", ["-e", script], timeout: 60) }.value
            return ToolResult(text: "exit \(r.status)\n" + r.output.truncated(10_000))

        case "open":
            let target = s("target")
            guard await approve(ctx, "Open", target) else { return declined() }
            let looksLikeApp = !target.contains("/") && !target.contains(".") && !target.contains(":")
            let r = await Task.detached { runProcess("/usr/bin/open", looksLikeApp ? ["-a", target] : [target], timeout: 20) }.value
            return ToolResult(text: r.status == 0 ? "Opened \(target)" : "Failed: \(r.output)")

        case "take_screenshot":
            guard await approve(ctx, "Take a screenshot", "Synapse wants to capture your screen and send it to the model.") else { return declined() }
            let path = Paths.images.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).png").path
            let r = await Task.detached { runProcess("/usr/sbin/screencapture", ["-x", "-C", path], timeout: 20) }.value
            guard r.status == 0, FileManager.default.fileExists(atPath: path) else {
                return ToolResult(text: "Screenshot failed. Grant Synapse Screen Recording permission in System Settings → Privacy & Security.")
            }
            return ToolResult(text: "Screenshot captured (attached as an image).", images: [path])

        case "browser_navigate":
            ctx.app.showBrowserPanel = true
            return ToolResult(text: await ctx.app.browser.navigate(s("url")).truncated(14_000))
        case "browser_read":
            return ToolResult(text: await ctx.app.browser.readPage().truncated(14_000))
        case "browser_click":
            let id = i("element")
            if let info = await ctx.app.browser.elementInfo(id), info.isSubmit || info.inPasswordForm {
                guard await approve(ctx, "Submit in browser", "Click “\(info.label)” on \(ctx.app.browser.url)? This may submit a form.", force: true)
                else { return declined() }
            }
            return ToolResult(text: await ctx.app.browser.click(id).truncated(14_000))
        case "browser_type":
            let id = i("element")
            if let info = await ctx.app.browser.elementInfo(id), info.type == "password" {
                return ToolResult(text: "Typing passwords is blocked. Ask the user to type it themselves in the Browser tab.")
            }
            if args["submit"] as? Bool == true, !(await approve(ctx, "Submit in browser", "Type “\(s("text"))” and press Enter on \(ctx.app.browser.url)?", force: true)) {
                return declined()
            }
            return ToolResult(text: await ctx.app.browser.type(id, text: s("text"), submit: args["submit"] as? Bool ?? false).truncated(14_000))
        case "browser_scroll":
            return ToolResult(text: await ctx.app.browser.scroll(s("direction")).truncated(14_000))
        case "browser_back":
            return ToolResult(text: await ctx.app.browser.back().truncated(14_000))
        case "browser_screenshot":
            guard let url = await ctx.app.browser.screenshot() else { return ToolResult(text: "Couldn't capture the browser.") }
            return ToolResult(text: "Browser screenshot attached.", images: [url.path])

        case "create_website":
            let name = s("name").ifEmpty("site")
            let files = (args["files"] as? [[String: Any]] ?? []).compactMap { f -> (path: String, content: String)? in
                guard let p = f["path"] as? String, let c = f["content"] as? String else { return nil }
                return (p, c)
            }
            guard !files.isEmpty else { return ToolResult(text: "No files given.") }
            do {
                let parent = ctx.project.map { $0.folderURL.appendingPathComponent("sites", isDirectory: true) }
                let site = try ctx.app.sites.create(name: name, files: files, in: parent)
                let url = site.url!.absoluteString
                ctx.app.showBrowserPanel = true
                ctx.app.browser.load(url)
                return ToolResult(text: "Website is live at \(url) (folder: \(site.folder.path)). It's open in the browser.", links: [url])
            } catch { return ToolResult(text: "Error: \(error.localizedDescription)") }

        default:
            return ToolResult(text: "Unknown tool \(call.name)")
        }
    }

    // MARK: Helpers

    static func denied() -> ToolResult {
        ToolResult(text: "Access denied: that path is outside the project folder. Turn on Computer Access to reach other files.")
    }
    static func declined() -> ToolResult { ToolResult(text: "The user declined this action.") }

    static func approve(_ ctx: ToolContext, _ title: String, _ detail: String, force: Bool = false, diff: FileDiff? = nil) async -> Bool {
        if ctx.autoApprove && !force { return true }
        return await ctx.app.requestApproval(title: title, detail: detail, diff: diff)
    }

    /// Shows the diff for approval first, then writes the file.
    static func applyChange(url: URL, old: String?, new: String, ctx: ToolContext) async -> ToolResult {
        let diff = Differ.diff(path: url.path, old: old, new: new)
        if old == new { return ToolResult(text: "No changes: \(url.lastPathComponent) already has this content.", diff: diff) }
        let verb = old == nil ? "Create" : "Update"
        guard await approve(ctx, "\(verb) \(url.lastPathComponent)", url.path, diff: diff) else { return declined() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try new.write(to: url, atomically: true, encoding: .utf8)
            let summary = old == nil ? "Created \(url.path) (\(diff.added) lines)"
                                     : "Updated \(url.path) with \(diff.added) additions and \(diff.removed) removals"
            return ToolResult(text: summary, diff: diff)
        } catch { return ToolResult(text: "Error: \(error.localizedDescription)") }
    }

    static func resolve(_ path: String, ctx: ToolContext) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : ctx.workDir.appendingPathComponent(expanded)).standardizedFileURL
        if ctx.capabilities.computerAccess { return url }
        if let p = ctx.project, url.path.hasPrefix(p.folderURL.standardizedFileURL.path) { return url }
        return nil
    }

    static func readText(_ url: URL) -> String {
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.string ?? "Couldn't read PDF."
        }
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let d = try? Data(contentsOf: url) {
            if let a = try? NSAttributedString(data: d, options: [:], documentAttributes: nil) { return a.string }
            return "Binary file (\(formatBytes(Int64(d.count)))), can't show as text."
        }
        return "File not found: \(url.path)"
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"

    static func webSearch(_ query: String) async -> ToolResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ToolResult(text: "Empty search query.") }
        // DuckDuckGo's HTML page first, its Lite page as a backup (their markup changes now and then).
        var results = await duckDuckGo(q, endpoint: "https://html.duckduckgo.com/html/")
        if results.isEmpty { results = await duckDuckGo(q, endpoint: "https://lite.duckduckgo.com/lite/") }
        guard !results.isEmpty else {
            return ToolResult(text: "No results for “\(q)” (the search service may be rate-limiting). Try fetch_url on a likely page instead.")
        }
        let lines = results.prefix(8).enumerated().map { n, r in "\(n + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)" }
        return ToolResult(text: "Results for “\(q)”:\n\n" + lines.joined(separator: "\n\n"))
    }

    struct SearchResult { let title: String; let url: String; let snippet: String }

    static func duckDuckGo(_ query: String, endpoint: String) async -> [SearchResult] {
        var req = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = Data(("q=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query) + "&kl=wt-wt").utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        let html = String(decoding: data, as: UTF8.self)

        // Every result link carries class "result__a" (HTML page) or "result-link" (Lite page), in any attribute order.
        let anchor = #"<a\b[^>]*class=['"][^'"]*\b(?:result__a|result-link)\b[^'"]*['"][^>]*>(.*?)</a>"#
        guard let re = try? NSRegularExpression(pattern: anchor, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [SearchResult] = []
        for (i, m) in matches.enumerated() {
            let tag = ns.substring(with: m.range)
            guard var link = firstMatch(#"href=['"]([^'"]+)['"]"#, tag) else { continue }
            link = link.replacingOccurrences(of: "&amp;", with: "&")
            if let r = link.range(of: "uddg="), let enc = link[r.upperBound...].split(separator: "&").first {
                link = String(enc).removingPercentEncoding ?? link
            }
            if link.hasPrefix("//") { link = "https:" + link }
            if link.contains("duckduckgo.com/y.js") || !link.hasPrefix("http") { continue }   // ads / internal
            let title = stripHTML(ns.substring(with: m.range(at: 1)))
            // The snippet sits between this result and the next one.
            let nextStart = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let tail = ns.substring(with: NSRange(location: m.range.location + m.range.length,
                                                  length: max(0, min(nextStart, ns.length) - m.range.location - m.range.length)))
            let snippet = stripHTML(firstMatch(#"class=['"][^'"]*(?:result__snippet|result-snippet)[^'"]*['"][^>]*>(.*?)</(?:a|td|div)>"#, tail) ?? "")
            if !out.contains(where: { $0.url == link }) { out.append(SearchResult(title: title, url: link, snippet: snippet)) }
        }
        return out
    }

    static func fetchURL(_ s: String) async -> ToolResult {
        guard let url = URL(string: s.contains("://") ? s : "https://" + s) else { return ToolResult(text: "Bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return ToolResult(text: "Couldn't load \(s)") }
        let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("pdf") { return ToolResult(text: (PDFDocument(data: data)?.string ?? "").truncated(40_000)) }
        let html = String(decoding: data, as: UTF8.self)
        if !type.contains("html") && !html.lowercased().contains("<html") { return ToolResult(text: html.truncated(40_000)) }
        let title = stripHTML(firstMatch(#"<title[^>]*>(.*?)</title>"#, html) ?? "")
        return ToolResult(text: "Title: \(title)\nURL: \(url.absoluteString)\n\n" + htmlToText(html).truncated(40_000))
    }

    static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func stripHTML(_ s: String) -> String {
        decodeEntities(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }

    static func htmlToText(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "head", "nav", "footer", "iframe"] {
            s = s.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<(br|/p|/div|/h[1-6]|/li|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        s = stripHTML(s)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s
    }
}

// MARK: - Image generation

enum ImageGen {
    static func generate(prompt: String, aspect: String) async -> ToolResult {
        let (w, h) = aspect == "landscape" ? (1344, 768) : aspect == "portrait" ? (768, 1344) : (1024, 1024)
        let file = Paths.images.appendingPathComponent("image-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).png")
        do {
            switch AppSettings.shared.imageProvider {
            case .pollinations:
                let enc = prompt.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? prompt
                let url = URL(string: "https://image.pollinations.ai/prompt/\(enc)?width=\(w)&height=\(h)&nologo=true&seed=\(Int.random(in: 1...999_999))")!
                let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 180))
                guard (resp as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil else {
                    throw APIError(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: "Image service returned no image")
                }
                try data.write(to: file)
            case .gemini:
                guard let key = Keychain.get("google") else { throw APIError(status: 0, message: "Add a Google AI Studio key first.") }
                let model = AppSettings.shared.geminiImageModel
                var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!, timeoutInterval: 180)
                req.httpMethod = "POST"
                req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let ratio = aspect == "landscape" ? "16:9" : aspect == "portrait" ? "9:16" : "1:1"
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "contents": [["parts": [["text": prompt]]]],
                    "generationConfig": ["responseModalities": ["TEXT", "IMAGE"], "imageConfig": ["aspectRatio": ratio]],
                ])
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    throw APIError(status: http.statusCode, message: ChatClient.errorMessage(from: data))
                }
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let parts = (((obj?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
                guard let b64 = parts.compactMap({ ($0["inlineData"] as? [String: Any])?["data"] as? String }).first,
                      let img = Data(base64Encoded: b64) else { throw APIError(status: 0, message: "Gemini returned no image") }
                try img.write(to: file)
            case .local:
                let candidates = [NSHomeDirectory() + "/.local/bin/mflux-generate", "/opt/homebrew/bin/mflux-generate"]
                guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                    throw APIError(status: 0, message: "mflux isn't installed. Run `uv tool install mflux` (needs 16 GB+ RAM), or choose another image provider in Settings.")
                }
                let r = await Task.detached {
                    runProcess(bin, ["--model", "schnell", "--steps", "2", "-q", "4", "--width", String(w), "--height", String(h),
                                     "--prompt", prompt, "--output", file.path], timeout: 1200)
                }.value
                guard FileManager.default.fileExists(atPath: file.path) else { throw APIError(status: 0, message: r.output.suffix(800).description) }
            }
            return ToolResult(text: "Image generated and shown to the user: \(file.path)", images: [file.path])
        } catch {
            return ToolResult(text: "Image generation failed: \(error.localizedDescription)")
        }
    }
}
