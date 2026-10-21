import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var renaming: Chat?
    @State private var renameText = ""
    @State private var newProject = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
                .toolbar {
                    ToolbarItem {
                        Button { app.newChat() } label: { Image(systemName: "square.and.pencil") }
                            .help("New chat (⌘N)")
                    }
                }
        } detail: {
            detail
                .background(Backdrop())
        }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                EngineStatusPill()
                if case .chat = app.selection {
                    Button { app.showBrowserPanel.toggle() } label: { Image(systemName: "globe") }
                        .help(app.showBrowserPanel ? "Hide browser" : "Show browser")
                }
                Button { app.showKeys = true } label: { Image(systemName: "key") }
                    .help("Accounts & API keys")
            }
        }
        .sheet(isPresented: $app.showKeys) { AccountsView().environment(app) }
        .sheet(item: Binding(get: { app.approvals.first }, set: { _ in })) { req in ApprovalView(request: req) }
        .sheet(isPresented: $newProject) { NewProjectSheet() }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let c = renaming, let i = app.chatIndex(c.id) { app.chats[i].title = renameText; app.save() }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var sidebar: some View {
        @Bindable var app = app
        return List(selection: $app.selection) {
            Section("Projects") {
                SidebarAction(title: "New Project", icon: "plus") { newProject = true }
                ForEach(app.projects) { p in
                    Label(p.name, systemImage: "folder").tag(SidebarItem.project(p.id))
                        .contextMenu {
                            Button("New Chat in Project") { app.newChat(project: p.id) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.folderURL]) }
                            Divider()
                            Button("Remove Project", role: .destructive) { app.deleteProject(p.id) }
                        }
                }
            }

            Section("Chats") {
                SidebarAction(title: "New Chat", icon: "square.and.pencil") { app.newChat() }
                ForEach(app.chats.sorted { $0.updatedAt > $1.updatedAt }) { c in
                    HStack(spacing: 6) {
                        Text(c.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if app.generating.contains(c.id) { ProgressView().controlSize(.mini) }
                    }
                    .tag(SidebarItem.chat(c.id))
                    .contextMenu {
                        Button("Rename…") { renameText = c.title; renaming = c }
                        Divider()
                        Button("Delete", role: .destructive) { app.deleteChat(c.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 1) {
                Divider().padding(.bottom, 6)
                SidebarFooterRow(title: "Models", icon: "cpu", item: .models)
                SidebarFooterRow(title: "Websites", icon: "globe", item: .sites)
                SidebarFooterRow(title: "Usage", icon: "chart.bar", item: .usage)
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.bottom, 10)
        }
    }

    @ViewBuilder private var detail: some View {
        switch app.selection {
        case .chat(let id): ChatView(chatID: id).id(id)
        case .project(let id): ProjectView(projectID: id).id(id)
        case .models: ModelsView()
        case .sites: SitesView()
        case .usage: UsageView()
        case .none: NoSelectionView()
        }
    }
}

struct SidebarAction: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SidebarFooterRow: View {
    @Environment(AppState.self) private var app
    let title: String
    let icon: String
    let item: SidebarItem

    var body: some View {
        let selected = app.selection == item
        Button { app.selection = item } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.fillStrong : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NoSelectionView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 14) {
            SynapseLogo(size: 44)
            Button("New Chat") { app.newChat() }.keyboardShortcut("n")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EngineStatusPill: View {
    @Environment(AppState.self) private var app

    var body: some View {
        switch app.engine.status {
        case .stopped: EmptyView()
        case .loading(let name):
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading \(name)").font(.caption).foregroundStyle(.secondary) }
        case .running(let name):
            Menu {
                Button("Eject \(name)") { app.engine.stop() }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text(name).font(.caption).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Loaded in memory")
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }
}

struct ApprovalView: View {
    @Environment(AppState.self) private var app
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title).font(.headline)
                Text("The model wants to do this. Allow only if you expect it.").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(request.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 240)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Deny", role: .cancel) { app.resolveApproval(request.id, false) }.keyboardShortcut(.cancelAction)
                Button("Allow") { app.resolveApproval(request.id, true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}

struct NewProjectSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.headline)
            Text("Chats in a project share its files and instructions.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Text(folder?.path ?? "~/Documents/Synapse Projects/\(SiteManager.slug(name.isEmpty ? "project" : name))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let u = panel.url {
                        folder = u
                        if name.isEmpty { name = u.lastPathComponent }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    app.newProject(name: name.isEmpty ? "Untitled Project" : name, folder: folder)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440)
    }
}
