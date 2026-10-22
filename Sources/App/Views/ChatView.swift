import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import QuickLookThumbnailing

struct ChatView: View {
    @Environment(AppState.self) private var app
    let chatID: UUID
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var importing = false
    @State private var dropTargeted = false

    private var chat: Chat? { app.chatIndex(chatID).map { app.chats[$0] } }
    private var isGenerating: Bool { app.generating.contains(chatID) }

    var body: some View {
        if let chat {
            HSplitView {
                VStack(spacing: 0) {
                    if chat.messages.isEmpty {
                        Spacer()
                        Greeting(project: app.project(for: chat)?.name)
                        composer
                        Spacer()
                        Spacer()
                    } else {
                        messages(chat)
                        composer
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity)
                if app.showBrowserPanel {
                    BrowserPanel(chatID: chatID).frame(minWidth: 380, idealWidth: 520)
                }
            }
            .navigationTitle(chat.title)
            .navigationSubtitle(app.project(for: chat)?.name ?? "")
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in handleDrop(providers); return true }
            .overlay { if dropTargeted { DropOverlay() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { attachments += urls.compactMap { app.makeAttachment(from: $0) } }
            }
        } else {
            NoSelectionView()
        }
    }

    // MARK: Messages

    private func messages(_ chat: Chat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    // Tool results render inside their call's step row, Claude Code style.
                    let results = Dictionary(chat.messages.compactMap { m in m.role == .tool ? (m.toolCallID ?? "", m) : nil },
                                             uniquingKeysWith: { a, _ in a })
                    ForEach(chat.messages.filter { $0.role != .tool }) { m in
                        MessageRow(message: m, isLast: m.id == chat.messages.last?.id, generating: isGenerating,
                                   results: results, onRegenerate: { app.regenerate(chatID: chatID) })
                            .id(m.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 12)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.messages.last?.content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            UsageBanner(chatID: chatID)
            Composer(chatID: chatID, draft: $draft, attachments: $attachments, isGenerating: isGenerating,
                 onAttach: { importing = true }, onSend: send, onStop: { app.stop(chatID) },
                 onPaste: handleDrop)
        }
            .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 4)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
    }

    private func send() {
        guard !isGenerating else { return }
        app.send(chatID: chatID, text: draft, attachments: attachments)
        draft = ""
        attachments = []
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in if let a = app.makeAttachment(from: url) { attachments.append(a) } }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage else { return }
                    Task { @MainActor in if let a = app.attachImage(img) { attachments.append(a) } }
                }
            }
        }
    }
}

struct Greeting: View {
    let project: String?
    var body: some View {
        VStack(spacing: 12) {
            SynapseLogo(size: 36)
            Text(project.map { "New chat in \($0)" } ?? "How can I help?")
                .font(.system(size: 24, weight: .medium))
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Composer

struct Composer: View {
    @Environment(AppState.self) private var app
    let chatID: UUID
    @Binding var draft: String
    @Binding var attachments: [Attachment]
    let isGenerating: Bool
    var onAttach: () -> Void
    var onSend: () -> Void
    var onStop: () -> Void
    var onPaste: ([NSItemProvider]) -> Void
    @FocusState private var focused: Bool

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    var body: some View {
        if let i = app.chatIndex(chatID) {
            VStack(alignment: .leading, spacing: 10) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachments) { a in AttachmentChip(attachment: a) { attachments.removeAll { $0.id == a.id } } }
                        }
                    }
                }
                TextField("Ask Synapse anything", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...12)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        if canSend && !isGenerating { onSend() }
                        return .handled
                    }
                    .onPasteCommand(of: [.image, .fileURL]) { onPaste($0) }
                    .padding(.horizontal, 4)

                HStack(spacing: 6) {
                    ToolsMenu(chatIndex: i, onAttach: onAttach)
                    ThinkPicker(level: Binding(get: { app.chats[i].think }, set: { app.chats[i].think = $0; app.save() }))
                    ActiveCapabilities(chatIndex: i)
                    Spacer(minLength: 8)
                    ModelPicker(selection: Binding(get: { app.chats[i].model ?? app.defaultModel }, set: { app.chats[i].model = $0; app.save() }))
                    Button(action: isGenerating ? onStop : onSend) {
                        Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: isGenerating ? 10 : 13, weight: .bold))
                            .foregroundStyle(isGenerating || canSend ? .white : .secondary)
                            .frame(width: 30, height: 30)
                            .glass(Circle(), tint: isGenerating || canSend ? Theme.accent : nil, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isGenerating && !canSend)
                    .keyboardShortcut(isGenerating ? "." : .return, modifiers: .command)
                    .help(isGenerating ? "Stop (⌘.)" : "Send (Return)")
                }
            }
            .padding(14)
            .glass(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .onAppear { focused = true }
        }
    }
}

struct PillLabel: View {
    let icon: String?
    let text: String
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)) }
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10).frame(height: 28)
        .background(Capsule().fill(Theme.fill))
        .contentShape(Capsule())
    }
}

struct ToolsMenu: View {
    @Environment(AppState.self) private var app
    let chatIndex: Int
    var onAttach: () -> Void

    var body: some View {
        let i = chatIndex
        Menu {
            Button { onAttach() } label: { Label("Add Files or Photos…", systemImage: "paperclip") }
            Divider()
            Section("Capabilities") {
                toggle("Web Search", "magnifyingglass", \.webSearch)
                toggle("Image Generation", "photo", \.imageGeneration)
                toggle("Computer Access", "desktopcomputer", \.computerAccess)
                toggle("Browser", "globe", \.browser)
                toggle("Build Websites", "chevron.left.forwardslash.chevron.right", \.websites)
            }
            if app.chats[i].capabilities.computerAccess || app.chats[i].capabilities.browser {
                Divider()
                Toggle("Run Actions Without Asking", isOn: Binding(get: { app.chats[i].autoApprove },
                                                                   set: { app.chats[i].autoApprove = $0; app.save() }))
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.fill))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Attach files and choose what the model can do")
    }

    private func toggle(_ title: String, _ icon: String, _ kp: WritableKeyPath<Capabilities, Bool>) -> some View {
        Toggle(isOn: Binding(get: { app.chats[chatIndex].capabilities[keyPath: kp] },
                             set: { app.chats[chatIndex].capabilities[keyPath: kp] = $0; app.save() })) {
            Label(title, systemImage: icon)
        }
    }
}

/// Small icons for the capabilities that are on; click one to turn it off.
struct ActiveCapabilities: View {
    @Environment(AppState.self) private var app
    let chatIndex: Int

    var body: some View {
        let c = app.chats[chatIndex].capabilities
        let items: [(String, String, WritableKeyPath<Capabilities, Bool>, Bool)] = [
            ("magnifyingglass", "Web search", \.webSearch, c.webSearch),
            ("photo", "Image generation", \.imageGeneration, c.imageGeneration),
            ("desktopcomputer", "Computer access", \.computerAccess, c.computerAccess),
            ("globe", "Browser", \.browser, c.browser),
            ("chevron.left.forwardslash.chevron.right", "Websites", \.websites, c.websites),
        ]
        HStack(spacing: 2) {
            ForEach(items.filter(\.3), id: \.1) { icon, name, kp, _ in
                Button {
                    app.chats[chatIndex].capabilities[keyPath: kp] = false
                    app.save()
                } label: {
                    Image(systemName: icon).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.accent.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("\(name) is on. Click to turn off.")
            }
        }
    }
}

struct ModelPicker: View {
    @Environment(AppState.self) private var app
    @Binding var selection: ModelRef?

    var body: some View {
        Menu {
            if !app.localModels.isEmpty {
                Section("On This Mac") {
                    ForEach(app.localModels) { m in
                        Button { selection = m.ref } label: { Label(m.displayName, systemImage: "cpu") }
                    }
                }
            }
            ForEach([ProviderID.google, .groq, .anthropic, .deepseek, .openrouter, .custom], id: \.self) { p in
                // Only offer models that actually work on this key (retired / paid-only ones are hidden).
                let list = (app.remoteModels[p] ?? []).filter { app.isUsable($0) }
                if !list.isEmpty {
                    Section(p.displayName) {
                        ForEach(list.prefix(40)) { m in
                            Button { selection = m } label: {
                                let busy = app.health(m) == .busy
                                if selection?.qualifiedID == m.qualifiedID {
                                    Label(m.name + (busy ? " · busy" : ""), systemImage: "checkmark")
                                } else {
                                    Text(m.name + (busy ? " · busy" : ""))
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Get More Models…") { app.selection = .models }
            Button("Accounts & API Keys…") { app.showKeys = true }
        } label: {
            PillLabel(icon: selection?.provider == .local ? "cpu" : "cloud", text: selection?.name ?? "Choose model")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

struct ThinkPicker: View {
    @Binding var level: ThinkLevel

    var body: some View {
        Menu {
            Picker("Thinking", selection: $level) {
                ForEach(ThinkLevel.allCases) { l in Text("\(l.label) — \(l.help)").tag(l) }
            }
            .pickerStyle(.inline)
        } label: {
            PillLabel(icon: "brain", text: level.label, tint: level == .high || level == .max ? Theme.accent : .secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("How hard the model thinks")
    }
}

// MARK: - Message rows

struct MessageRow: View {
    let message: ChatMessage
    let isLast: Bool
    let generating: Bool
    var results: [String: ChatMessage] = [:]
    var onRegenerate: () -> Void

    var body: some View {
        switch message.role {
        case .user: userRow
        case .assistant: assistantRow
        case .tool, .system: EmptyView()
        }
    }

    private var userRow: some View {
        HStack {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(message.attachments) { a in
                    if a.kind == .image, let img = NSImage(contentsOfFile: a.path) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        AttachmentChip(attachment: a, onRemove: nil)
                    }
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: Theme.accent.opacity(0.25))
                }
            }
        }
    }

    private var live: Bool { generating && isLast }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if live && message.content.isEmpty && message.toolCalls.isEmpty {
                if message.reasoning.isEmpty && message.status == nil { TypingDots() }
                else { ThinkingIndicator(message: message, live: true) }
            } else if message.content.isEmpty == false && message.thinkingSeconds != nil {
                ThinkingIndicator(message: message, live: false)
            }
            if !message.content.isEmpty {
                if message.isError {
                    Label { Text(message.content).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(.callout).foregroundStyle(.red)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.07)))
                } else {
                    MarkdownView(text: message.content)
                }
            }
            if !message.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(message.toolCalls) { c in
                        ToolStep(call: c, result: results[c.id], running: generating && results[c.id] == nil)
                    }
                }
                .padding(.vertical, 2)
            }
            if !message.content.isEmpty && !live && message.toolCalls.isEmpty && !message.isError {
                HStack(spacing: 14) {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string) } label: {
                        Image(systemName: "doc.on.doc")
                    }.help("Copy")
                    if isLast { Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }.help("Retry") }
                    if let name = message.modelName { Text(name).font(.caption) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thinking is private: show that the model is thinking (and for how long), never what it thought.
struct ThinkingIndicator: View {
    let message: ChatMessage
    let live: Bool

    var body: some View {
        if live {
            TimelineView(.periodic(from: .now, by: 1)) { t in
                HStack(spacing: 7) {
                    PulsingDot()
                    Text(message.status ?? "Thinking")
                    Text("\(Int(t.date.timeIntervalSince(message.createdAt)))s").monospacedDigit().foregroundStyle(.tertiary)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        } else if let s = message.thinkingSeconds, s >= 1 {
            Text("Thought for \(Int(s.rounded()))s").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// A file the model made or shared, shown as a compact glass attachment (decks can be presented).
struct FileCard: View {
    let path: String
    @State private var preview: URL?
    @State private var thumbnail: NSImage?

    private var url: URL { URL(fileURLWithPath: path) }
    private var ext: String { url.pathExtension.lowercased() }
    private var isDeck: Bool { ["pptx", "ppt", "key"].contains(ext) }
    private var wide: Bool { isDeck || ["pdf", "docx", "doc", "pages"].contains(ext) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit().padding(wide ? 14 : 2)
                }
            }
            .frame(width: wide ? 104 : 40, height: wide ? 58 : 40)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            .onTapGesture { preview = url }

            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(kindLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isDeck {
                Button { preview = url } label: {
                    Label("Present", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .glass(Capsule(), tint: Theme.accent.opacity(0.85), interactive: true)
                }
                .buttonStyle(.plain)
                .help("Present with Quick Look (use the arrow keys to move between slides)")
            } else {
                Button { preview = url } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("Preview")
            }
            Menu {
                Button("Open in Default App") { NSWorkspace.shared.open(url) }
                if isDeck {
                    Button("Open in Keynote") {
                        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Keynote.app"),
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: 470)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .quickLookPreview($preview)
        .task(id: path) { thumbnail = await Self.makeThumbnail(url) }
    }

    private var kindLabel: String {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64).flatMap { $0 }.map(formatBytes) ?? ""
        let kind: String
        switch ext {
        case "pptx", "ppt": kind = "PowerPoint presentation"
        case "key": kind = "Keynote presentation"
        case "pdf": kind = "PDF document"
        case "docx", "doc": kind = "Word document"
        default: kind = ext.uppercased() + " file"
        }
        return size.isEmpty ? kind : "\(kind) · \(size)"
    }

    static func makeThumbnail(_ url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 208, height: 116), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if attachment.kind == .image, let img = NSImage(contentsOfFile: attachment.path) {
                Image(nsImage: img).resizable().scaledToFill().frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "doc.text").foregroundStyle(.secondary)
            }
            Text(attachment.filename).lineLimit(1).font(.caption)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { t in
            let p = t.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary).frame(width: 6, height: 6)
                        .opacity(0.25 + 0.6 * max(0, sin(p * 5 - Double(i) * 0.7)))
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6]))
            .background(Theme.accent.opacity(0.05))
            .overlay(Text("Drop to attach").font(.headline).foregroundStyle(Theme.accent))
            .padding(10)
            .allowsHitTesting(false)
    }
}


/// Warns above the composer when the chat's provider is close to its rate limit.
struct UsageBanner: View {
    @Environment(AppState.self) private var app
    let chatID: UUID

    var body: some View {
        if let i = app.chatIndex(chatID), let p = (app.chats[i].model ?? app.defaultModel)?.provider,
           let warning = app.usageWarning(for: p), !app.dismissedWarnings.contains(warning) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(.orange)
                Text(warning).font(.system(size: 12)).lineLimit(2)
                Spacer(minLength: 6)
                Button("Usage") { app.selection = .usage }.buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
                Button { app.dismissedWarnings.insert(warning) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glass(Capsule(), tint: Color.orange.opacity(0.18))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
