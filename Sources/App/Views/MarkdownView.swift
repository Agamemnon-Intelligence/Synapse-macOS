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
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if ["html", "htm"].contains(language.lowercased()) {
                    Button("Preview") { previewHTML() }.font(.caption).buttonStyle(.borderless)
                }
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .font(.caption).buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.06))
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func previewHTML() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synapse-preview-\(UUID().uuidString.prefix(6)).html")
        try? code.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
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
