import SwiftUI
import UniformTypeIdentifiers
import QuickLook

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
                    ForEach(chat.messages) { m in
                        MessageRow(message: m, isLast: m.id == chat.messages.last?.id, generating: isGenerating,
                                   onRegenerate: { app.regenerate(chatID: chatID) })
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
        Composer(chatID: chatID, draft: $draft, attachments: $attachments, isGenerating: isGenerating,
                 onAttach: { importing = true }, onSend: send, onStop: { app.stop(chatID) },
                 onPaste: handleDrop)
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
            ForEach([ProviderID.google, .groq, .openrouter, .custom], id: \.self) { p in
                if let list = app.remoteModels[p], !list.isEmpty {
                    Section(p.displayName) {
                        ForEach(list.prefix(40)) { m in Button(m.name) { selection = m } }
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
    var onRegenerate: () -> Void

    var body: some View {
        switch message.role {
        case .user: userRow
        case .assistant: assistantRow
        case .tool: ToolRow(message: message)
        case .system: EmptyView()
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
            if !message.reasoning.isEmpty {
                ReasoningView(text: message.reasoning, live: live && message.content.isEmpty)
            }
            if message.content.isEmpty && message.toolCalls.isEmpty && message.reasoning.isEmpty && live {
                TypingDots()
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
            ForEach(message.toolCalls) { c in ToolCallLabel(call: c) }
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

struct ReasoningView: View {
    let text: String
    let live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Text(live ? "Thinking" : "Thought process")
                    if live { ProgressView().controlSize(.mini) }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
            }
        }
    }
}

struct ToolCallLabel: View {
    let call: ToolCall

    var body: some View {
        let (icon, text) = Self.describe(call)
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    static func describe(_ c: ToolCall) -> (String, String) {
        let a = (try? JSONSerialization.jsonObject(with: Data(c.arguments.utf8)) as? [String: Any]) ?? [:]
        let v: (String) -> String = { (a[$0] as? String) ?? (a[$0].map { "\($0)" } ?? "") }
        switch c.name {
        case "web_search": return ("magnifyingglass", "Searched “\(v("query"))”")
        case "fetch_url": return ("doc.text", "Read \(URL(string: v("url"))?.host ?? v("url"))")
        case "generate_image": return ("photo", "Generated an image")
        case "run_shell": return ("terminal", v("command"))
        case "run_applescript": return ("applescript", "Ran AppleScript")
        case "open": return ("arrow.up.forward.app", "Opened \(v("target"))")
        case "take_screenshot": return ("camera.viewfinder", "Took a screenshot")
        case "list_files": return ("folder", "Listed \(v("path").ifEmpty("files"))")
        case "read_file": return ("doc", "Read \((v("path") as NSString).lastPathComponent)")
        case "write_file": return ("square.and.pencil", "Wrote \((v("path") as NSString).lastPathComponent)")
        case "present_file": return ("eye", "Shared \((v("path") as NSString).lastPathComponent)")
        case "browser_navigate": return ("globe", "Opened \(URL(string: v("url"))?.host ?? v("url"))")
        case "browser_read": return ("doc.richtext", "Read the page")
        case "browser_click": return ("cursorarrow.click", "Clicked")
        case "browser_type": return ("keyboard", "Typed “\(v("text"))”")
        case "browser_scroll": return ("arrow.up.and.down", "Scrolled \(v("direction"))")
        case "browser_back": return ("chevron.backward", "Went back")
        case "browser_screenshot": return ("camera", "Looked at the page")
        case "create_website": return ("chevron.left.forwardslash.chevron.right", "Built “\(v("name"))”")
        default: return ("wrench.and.screwdriver", c.name)
        }
    }
}

struct ToolRow: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(expanded ? "Hide output" : "Output")
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 21)
            if expanded {
                ScrollView {
                    Text(message.content)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(message.images, id: \.self) { path in
                if let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img).resizable().scaledToFit()
                        .frame(maxWidth: 480, maxHeight: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
            }
            ForEach(message.presentedFiles, id: \.self) { path in FileCard(path: path) }
            ForEach(message.links, id: \.self) { link in
                if let url = URL(string: link) {
                    Link(destination: url) { Label(link, systemImage: "arrow.up.right.square") }.font(.callout)
                }
            }
        }
        .padding(.top, -12)
    }
}

struct FileCard: View {
    let path: String
    @State private var preview: URL?

    var body: some View {
        let url = URL(fileURLWithPath: path)
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.callout.weight(.medium))
                Text(url.pathExtension.uppercased()).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Preview") { preview = url }.controlSize(.small)
            Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .quickLookPreview($preview)
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
