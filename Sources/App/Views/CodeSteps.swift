import SwiftUI

/// One tool call rendered like a terminal coding agent:
///   ⏺ Update(ChatView.swift)  +34 −15
///     ⎿  Updated with 34 additions and 15 removals
/// followed by the diff, command output, images or files.
struct ToolStep: View {
    let call: ToolCall
    let result: ChatMessage?
    let running: Bool
    @State private var expanded = false

    private var args: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
    }
    private func arg(_ k: String) -> String { (args[k] as? String) ?? (args[k].map { "\($0)" } ?? "") }

    private var state: StepState {
        guard let r = result else { return running ? .running : .failed }
        if r.content.hasPrefix("The user declined") { return .declined }
        if r.content.hasPrefix("Error") || r.content.hasPrefix("Access denied") || shellExitCode.map({ $0 != 0 }) == true { return .failed }
        return .done
    }

    private var shellExitCode: Int? {
        guard call.name == "run_shell" || call.name == "run_applescript", let r = result?.content,
              r.hasPrefix("exit "), let line = r.split(separator: "\n").first else { return nil }
        return Int(line.dropFirst(5))
    }

    private var shellOutput: String {
        guard let r = result?.content else { return "" }
        return r.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if let summary {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("⎿").foregroundStyle(.tertiary)
                    Text(summary).foregroundStyle(state == .failed ? AnyShapeStyle(Color.red.opacity(0.9)) : AnyShapeStyle(.secondary))
                        .lineLimit(expanded ? nil : 3)
                        .textSelection(.enabled)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.leading, 18)
            }
            if let diff = result?.diff, diff.added + diff.removed > 0, state != .declined {
                DiffView(diff: diff, collapsedLines: 14)
                    .padding(.leading, 18)
            } else if expanded, let text = detailText, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                .padding(.leading, 18)
            }
            if let r = result {
                ForEach(r.images, id: \.self) { path in
                    if let img = NSImage(contentsOfFile: path) {
                        Image(nsImage: img).resizable().scaledToFit()
                            .frame(maxWidth: 480, maxHeight: 480)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            .padding(.leading, 18).padding(.top, 4)
                    }
                }
                ForEach(r.presentedFiles, id: \.self) { path in FileCard(path: path).padding(.leading, 18).padding(.top, 4) }
                ForEach(r.links, id: \.self) { link in
                    if let url = URL(string: link) {
                        Link(destination: url) { Label(link, systemImage: "arrow.up.right.square") }
                            .font(.system(size: 12, design: .monospaced)).padding(.leading, 18)
                    }
                }
            }
        }
    }

    private var header: some View {
        let (verb, target) = Self.describe(call.name, args: args)
        return Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
            HStack(spacing: 8) {
                StatusDot(state: state)
                (Text(verb).fontWeight(.semibold).foregroundColor(.primary)
                 + Text(target.isEmpty ? "" : "(\(target))").foregroundColor(.secondary))
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                if let d = result?.diff, d.added + d.removed > 0, state != .declined { DiffCounts(added: d.added, removed: d.removed) }
                Spacer(minLength: 0)
                if detailText?.isEmpty == false, result?.diff == nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide details" : "Show details")
    }

    /// The one-line result under the header.
    private var summary: String? {
        guard let r = result else { return running ? "Running…" : nil }
        if state == .declined { return "Denied by you" }
        if let d = r.diff {
            if d.added + d.removed == 0 { return "No changes" }
            return d.isNewFile ? "Created with \(d.added) line\(d.added == 1 ? "" : "s")"
                               : "Updated with \(d.added) addition\(d.added == 1 ? "" : "s") and \(d.removed) removal\(d.removed == 1 ? "" : "s")"
        }
        switch call.name {
        case "run_shell", "run_applescript":
            let out = shellOutput
            if out.isEmpty { return shellExitCode == 0 ? "(no output)" : "Exited with code \(shellExitCode ?? -1)" }
            let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
            let head = lines.prefix(4).joined(separator: "\n")
            return lines.count > 4 ? head + "\n… +\(lines.count - 4) lines" : head
        case "web_search":
            let n = r.content.split(separator: "\n").filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }.count
            return n == 0 ? "No results" : "Found \(n) result\(n == 1 ? "" : "s")"
        case "read_file":
            let n = r.content.split(separator: "\n", omittingEmptySubsequences: false).count
            return r.content.hasPrefix("File not found") ? r.content : "Read \(n) line\(n == 1 ? "" : "s")"
        case "list_files":
            return "Listed \(max(0, r.content.split(separator: "\n").count - 1)) items"
        case "fetch_url":
            return "Read \(formatBytes(Int64(r.content.utf8.count))) of text"
        default:
            let first = r.content.split(separator: "\n").first.map(String.init) ?? ""
            return first.count > 160 ? String(first.prefix(160)) + "…" : first
        }
    }

    /// What expanding the step shows.
    private var detailText: String? {
        guard let r = result, state != .declined else { return nil }
        switch call.name {
        case "run_shell", "run_applescript": return shellOutput
        case "create_presentation", "present_file", "generate_image", "take_screenshot", "browser_screenshot": return nil
        default: return r.content
        }
    }

    static func describe(_ name: String, args: [String: Any]) -> (String, String) {
        let v: (String) -> String = { (args[$0] as? String) ?? (args[$0].map { "\($0)" } ?? "") }
        let file: (String) -> String = { (v($0) as NSString).lastPathComponent }
        switch name {
        case "run_shell": return ("Bash", v("command"))
        case "run_applescript": return ("AppleScript", v("script").split(separator: "\n").first.map(String.init) ?? "")
        case "write_file": return ("Write", file("path"))
        case "edit_file": return ("Update", file("path"))
        case "read_file": return ("Read", file("path"))
        case "list_files": return ("List", v("path").ifEmpty("."))
        case "present_file": return ("Present", file("path"))
        case "web_search": return ("Search", "\"\(v("query"))\"")
        case "fetch_url": return ("Fetch", URL(string: v("url"))?.host ?? v("url"))
        case "generate_image": return ("Image", v("prompt"))
        case "create_presentation": return ("Presentation", v("title"))
        case "create_website": return ("Website", v("name"))
        case "open": return ("Open", v("target"))
        case "take_screenshot": return ("Screenshot", "")
        case "browser_navigate": return ("Browse", URL(string: v("url"))?.host ?? v("url"))
        case "browser_read": return ("Browse", "read page")
        case "browser_click": return ("Browse", "click #\(v("element"))")
        case "browser_type": return ("Browse", "type \"\(v("text"))\"")
        case "browser_scroll": return ("Browse", "scroll \(v("direction"))")
        case "browser_back": return ("Browse", "back")
        case "browser_screenshot": return ("Browse", "look at page")
        default: return (name, "")
        }
    }
}

private struct StatusDot: View {
    let state: StepState

    var body: some View {
        Group {
            if state == .running {
                TimelineView(.animation) { t in
                    let p = (sin(t.date.timeIntervalSinceReferenceDate * 5) + 1) / 2
                    Circle().fill(Color.secondary).opacity(0.35 + 0.65 * p)
                }
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8)
        .frame(width: 10)
    }

    private var color: Color {
        switch state {
        case .done: return Color(red: 0.30, green: 0.82, blue: 0.48)
        case .failed: return Color(red: 0.95, green: 0.36, blue: 0.33)
        case .declined: return Color.orange
        case .running: return .secondary
        }
    }
}

enum StepState { case running, done, failed, declined }

/// "+34 −15" in green and red.
struct DiffCounts: View {
    let added: Int
    let removed: Int
    var body: some View {
        HStack(spacing: 6) {
            if added > 0 { Text("+\(added)").foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.50)) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Color(red: 0.98, green: 0.42, blue: 0.40)) }
        }
        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
    }
}

/// A unified diff: removed lines on red, added lines on green, with a +/− gutter.
struct DiffView: View {
    let diff: FileDiff
    var collapsedLines = 14
    @State private var expanded = false

    private static let addBG = Color(red: 0.20, green: 0.75, blue: 0.40).opacity(0.14)
    private static let delBG = Color(red: 0.95, green: 0.30, blue: 0.30).opacity(0.14)
    private static let addFG = Color(red: 0.55, green: 0.92, blue: 0.62)
    private static let delFG = Color(red: 1.0, green: 0.58, blue: 0.55)

    var body: some View {
        let lines = expanded ? diff.lines : Array(diff.lines.prefix(collapsedLines))
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                                .frame(width: 22, alignment: .center)
                                .foregroundStyle(line.kind == .added ? Self.addFG : line.kind == .removed ? Self.delFG : Color.secondary.opacity(0.5))
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.kind == .added ? Self.addFG : line.kind == .removed ? Self.delFG : Color.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 12)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 1)
                        .frame(minWidth: 520, alignment: .leading)
                        .background(line.kind == .added ? Self.addBG : line.kind == .removed ? Self.delBG : Color.clear)
                    }
                }
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
            if diff.lines.count > collapsedLines {
                Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                    Text(expanded ? "Show less" : "Show \(diff.lines.count - collapsedLines) more lines")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.03))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}
