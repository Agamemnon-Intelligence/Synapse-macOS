import SwiftUI

/// Lightweight Markdown renderer: headings, lists, quotes, tables, code blocks, inline styles.
struct MarkdownView: View {
    let text: String

    enum Block: Hashable {
        case paragraph(String)
        case heading(Int, String)
        case code(String, String)
        case table([String])
        case quote(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let s):
                    Text(Self.inline(s)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                case .heading(let level, let s):
                    Text(Self.inline(s))
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                case .code(let lang, let code):
                    CodeBlock(language: lang, code: code)
                case .table(let rows):
                    TableBlock(rows: rows)
                case .quote(let s):
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.6)).frame(width: 3)
                        Text(Self.inline(s)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                case .rule:
                    Divider()
                }
            }
        }
        .font(.system(size: 14))
    }

    static func inline(_ s: String) -> AttributedString {
        let text = simplifyMath(s)
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// Turns simple inline LaTeX ($17 \times 23$) into plain symbols.
    static func simplifyMath(_ s: String) -> String {
        guard s.contains("$") || s.contains("\\") else { return s }
        var out = s
        let symbols: [(String, String)] = [("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"), ("\\pm", "±"), ("\\leq", "≤"), ("\\geq", "≥"),
                                           ("\\le", "≤"), ("\\ge", "≥"), ("\\neq", "≠"), ("\\approx", "≈"), ("\\infty", "∞"),
                                           ("\\sqrt", "√"), ("\\pi", "π"), ("\\rightarrow", "→"), ("\\to", "→"), ("\\sum", "Σ"),
                                           ("\\alpha", "α"), ("\\beta", "β"), ("\\theta", "θ"), ("\\lambda", "λ"), ("\\mu", "μ")]
        for (k, v) in symbols { out = out.replacingOccurrences(of: k, with: v) }
        out = out.replacingOccurrences(of: #"\\(?:text|mathrm|mathbf)\{([^}]*)\}"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\\frac\{([^}]*)\}\{([^}]*)\}"#, with: "$1⁄$2", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\$\$?([^$\n]+?)\$\$?"#, with: "$1", options: .regularExpression)
        return out
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var table: [String] = []
        var quote: [String] = []
        var code: [String]? = nil
        var lang = ""

        func flushPara() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushTable() { if !table.isEmpty { blocks.append(.table(table)); table = [] } }
        func flushQuote() { if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        func flushAll() { flushPara(); flushTable(); flushQuote() }

        for raw in text.components(separatedBy: "\n") {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lang, code!.joined(separator: "\n")))
                    code = nil
                } else { code!.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushAll()
                lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            if trimmed.hasPrefix("|") {
                flushPara(); flushQuote()
                table.append(trimmed)
                continue
            } else { flushTable() }
            if trimmed.hasPrefix(">") {
                flushPara()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            } else { flushQuote() }
            if let m = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flushPara()
                let level = trimmed[m].filter { $0 == "#" }.count
                blocks.append(.heading(level, String(trimmed[m.upperBound...])))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flushPara(); blocks.append(.rule); continue }
            if trimmed.isEmpty { flushPara(); continue }
            // Bullets → •, keep indentation.
            var l = line
            if let r = l.range(of: #"^(\s*)[-*+] "#, options: .regularExpression) {
                let indent = String(l[r].prefix { $0 == " " })
                l = indent + "•  " + l[r.upperBound...]
            }
            para.append(l)
        }
        if let code { blocks.append(.code(lang, code.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false
    @State private var expanded = false
    @State private var hovering = false

    private var lines: [Substring] { code.split(separator: "\n", omittingEmptySubsequences: false) }
    private var collapsible: Bool { lines.count > 28 }

    var body: some View {
        let lang = CodeLanguage(language)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: lang.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(lang.color)
                Text(lang.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary.opacity(0.85))
                Text("\(lines.count) line\(lines.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if ["html", "htm", "svg"].contains(language.lowercased()) {
                    headerButton("Preview", "eye") { previewHTML() }
                }
                headerButton("Save", "square.and.arrow.down") { save(lang) }
                headerButton(copied ? "Copied" : "Copy", copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.snappy) { copied = false } }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.white.opacity(0.035))
            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    // Line numbers.
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(Array(visibleLines.enumerated()), id: \.offset) { i, _ in
                            Text("\(i + 1)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.quaternary)
                        }
                    }
                    Text(SyntaxHighlighter.highlight(visibleLines.joined(separator: "\n"), language: lang))
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(0)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            if collapsible {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                        Text(expanded ? "Show less" : "Show all \(lines.count) lines")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.03))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            ZStack {
                Color(red: 0.055, green: 0.06, blue: 0.075)
                LinearGradient(colors: [lang.color.opacity(0.07), .clear], startPoint: .topLeading, endPoint: .center)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(hovering ? 0.18 : 0.11), Color.white.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private var visibleLines: [Substring] { collapsible && !expanded ? Array(lines.prefix(20)) : lines }

    private func headerButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.07 : 0.0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func save(_ lang: CodeLanguage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "code." + lang.fileExtension
        if panel.runModal() == .OK, let url = panel.url { try? code.write(to: url, atomically: true, encoding: .utf8) }
    }

    private func previewHTML() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synapse-preview-\(UUID().uuidString.prefix(6)).html")
        try? code.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }
}

struct CodeLanguage {
    let id: String
    init(_ raw: String) { id = raw.lowercased().trimmingCharacters(in: .whitespaces) }

    var name: String {
        switch id {
        case "", "text", "plaintext": return "Code"
        case "js", "javascript": return "JavaScript"
        case "ts", "typescript": return "TypeScript"
        case "py", "python": return "Python"
        case "sh", "bash", "zsh", "shell": return "Shell"
        case "html", "htm": return "HTML"
        case "css": return "CSS"
        case "json": return "JSON"
        case "cpp", "c++": return "C++"
        case "csharp", "cs": return "C#"
        case "objc", "objective-c": return "Objective-C"
        case "md", "markdown": return "Markdown"
        case "yml", "yaml": return "YAML"
        case "sql": return "SQL"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    var fileExtension: String {
        ["javascript": "js", "typescript": "ts", "python": "py", "bash": "sh", "shell": "sh", "zsh": "sh", "markdown": "md",
         "swift": "swift", "rust": "rs", "kotlin": "kt", "ruby": "rb", "csharp": "cs", "c++": "cpp", "objective-c": "m", "": "txt"][id] ?? id
    }

    var symbol: String {
        switch id {
        case "swift": return "swift"
        case "sh", "bash", "zsh", "shell": return "terminal"
        case "html", "htm", "xml", "svg": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "sql": return "cylinder"
        case "md", "markdown": return "text.alignleft"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// A small per-language tint (never purple) for the header icon and a faint glow.
    var color: Color {
        switch id {
        case "swift": return Color(red: 1.0, green: 0.45, blue: 0.25)
        case "py", "python": return Color(red: 0.98, green: 0.80, blue: 0.25)
        case "js", "javascript", "json": return Color(red: 0.97, green: 0.85, blue: 0.30)
        case "ts", "typescript": return Color(red: 0.25, green: 0.60, blue: 1.0)
        case "html", "htm", "xml", "svg": return Color(red: 0.95, green: 0.45, blue: 0.25)
        case "css": return Color(red: 0.20, green: 0.70, blue: 0.95)
        case "sh", "bash", "zsh", "shell": return Color(red: 0.35, green: 0.85, blue: 0.55)
        case "rust", "rs": return Color(red: 0.90, green: 0.55, blue: 0.35)
        case "go": return Color(red: 0.30, green: 0.80, blue: 0.90)
        default: return Color(red: 0.25, green: 0.75, blue: 0.95)
        }
    }

    var hashComments: Bool { ["py", "python", "sh", "bash", "zsh", "shell", "ruby", "rb", "yaml", "yml", "toml", "r", "perl", "dockerfile", "make", "makefile"].contains(id) }
    var markup: Bool { ["html", "htm", "xml", "svg"].contains(id) }
}

enum SyntaxHighlighter {
    static let keywordColor = Color(red: 1.0, green: 0.48, blue: 0.42)     // coral
    static let stringColor = Color(red: 0.58, green: 0.86, blue: 0.56)      // soft green
    static let numberColor = Color(red: 1.0, green: 0.80, blue: 0.36)       // amber
    static let commentColor = Color(red: 0.42, green: 0.45, blue: 0.52)     // slate
    static let typeColor = Color(red: 0.36, green: 0.80, blue: 1.0)         // sky
    static let funcColor = Color(red: 0.45, green: 0.90, blue: 0.82)        // teal
    static let plainColor = Color(red: 0.86, green: 0.88, blue: 0.92)

    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "guard", "return", "for", "while", "in", "switch", "case", "default", "break", "continue",
        "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "fileprivate", "internal", "static", "final",
        "self", "Self", "super", "init", "deinit", "nil", "true", "false", "try", "catch", "throw", "throws", "async", "await", "do",
        "some", "any", "where", "as", "is", "inout", "override", "mutating", "lazy", "weak", "defer", "repeat",
        "def", "lambda", "None", "True", "False", "and", "or", "not", "elif", "pass", "with", "yield", "from", "global", "nonlocal",
        "function", "const", "new", "this", "typeof", "instanceof", "export", "interface", "type", "implements", "extends", "null",
        "undefined", "void", "delete", "of", "package", "fn", "pub", "impl", "mod", "use", "match", "loop", "mut", "crate", "trait",
        "int", "float", "double", "char", "bool", "long", "short", "unsigned", "include", "define", "namespace", "template", "typename",
        "echo", "then", "fi", "done", "esac", "elif", "local", "export", "select", "from", "where", "insert", "update", "into", "values",
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "INTO", "VALUES", "JOIN", "ON", "GROUP", "BY", "ORDER", "CREATE", "TABLE",
    ]

    static func highlight(_ code: String, language: CodeLanguage) -> AttributedString {
        var out = AttributedString(code)
        out.foregroundColor = plainColor
        guard code.count < 60_000 else { return out }
        let ns = code as NSString
        let comment = language.markup ? #"<!--[\s\S]*?-->"# : (language.hashComments ? #"#[^\n]*"# : #"//[^\n]*|/\*[\s\S]*?\*/"#)
        let pattern = "(?<comment>\(comment))|(?<string>\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'|`[^`]*`)"
            + #"|(?<number>\b\d+(?:\.\d+)?\b)|(?<word>[A-Za-z_][A-Za-z0-9_]*)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            var color: Color?
            var italic = false
            if m.range(withName: "comment").location != NSNotFound { color = commentColor; italic = true }
            else if m.range(withName: "string").location != NSNotFound { color = stringColor }
            else if m.range(withName: "number").location != NSNotFound { color = numberColor }
            else if m.range(withName: "word").location != NSNotFound {
                let word = ns.substring(with: m.range)
                if keywords.contains(word) { color = keywordColor }
                else if word.first?.isUppercase == true { color = typeColor }
                else {
                    let after = m.range.location + m.range.length
                    if after < ns.length, ns.character(at: after) == 40 { color = funcColor }   // "("
                }
            }
            guard let color, let r = Range(m.range, in: code), let ar = Range(r, in: out) else { continue }
            out[ar].foregroundColor = color
            if italic { out[ar].font = .system(size: 12.5, design: .monospaced).italic() }
        }
        return out
    }
}

struct TableBlock: View {
    let rows: [String]

    var body: some View {
        let parsed = rows
            .filter { !$0.replacingOccurrences(of: #"[|:\-\s]"#, with: "", options: .regularExpression).isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
        let cols = parsed.map(\.count).max() ?? 0
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { idx, row in
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        Text(MarkdownView.inline(c < row.count ? row[c] : ""))
                            .fontWeight(idx == 0 ? .semibold : .regular)
                            .textSelection(.enabled)
                    }
                }
                if idx == 0 { Divider() }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}
