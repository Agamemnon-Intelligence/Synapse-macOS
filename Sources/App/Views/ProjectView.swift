import SwiftUI
import QuickLook

struct ProjectView: View {
    @Environment(AppState.self) private var app
    let projectID: UUID
    @State private var files: [String] = []
    @State private var preview: URL?
    @State private var importing = false
    @State private var dropTargeted = false

    private var index: Int? { app.projects.firstIndex { $0.id == projectID } }

    var body: some View {
        if let i = index {
            let p = app.projects[i]
            HSplitView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "folder").font(.system(size: 22)).foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            TextField("Name", text: Binding(get: { app.projects[i].name }, set: { app.projects[i].name = $0; app.save() }))
                                .font(.system(size: 22, weight: .semibold)).textFieldStyle(.plain)
                            Text(p.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { app.newChat(project: p.id) } label: { Label("New Chat", systemImage: "plus.bubble") }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instructions").font(.headline)
                        Text("Every chat in this project follows these (tone, goals, rules, context).").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { app.projects[i].instructions }, set: { app.projects[i].instructions = $0; app.save() }))
                            .font(.body)
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Chats").font(.headline)
                        let chats = app.chats.filter { $0.projectID == p.id }.sorted { $0.updatedAt > $1.updatedAt }
                        if chats.isEmpty { Text("No chats yet.").foregroundStyle(.secondary) }
                        ForEach(chats) { c in
                            Button { app.selection = .chat(c.id) } label: {
                                HStack {
                                    Image(systemName: "bubble.left")
                                    Text(c.title)
                                    Spacer()
                                    Text(c.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                }
                .padding(24)
                .frame(minWidth: 380)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Files").font(.headline)
                        Spacer()
                        Button { importing = true } label: { Image(systemName: "plus") }.help("Add files")
                        Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                        Button { NSWorkspace.shared.open(p.folderURL) } label: { Image(systemName: "folder") }.help("Open in Finder")
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                    Divider()
                    if files.isEmpty {
                        ContentUnavailableView("No files", systemImage: "doc.badge.plus",
                                               description: Text("Drop files here. Chats in this project can read them, and the AI can create new ones."))
                    } else {
                        List(files, id: \.self) { f in
                            let url = p.folderURL.appendingPathComponent(f)
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                                Text(f).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                            .onTapGesture { preview = url }
                            .contextMenu {
                                Button("Quick Look") { preview = url }
                                Button("Open") { NSWorkspace.shared.open(url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("Move to Trash", role: .destructive) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil); reload() }
                            }
                        }
                    }
                }
                .frame(minWidth: 260, idealWidth: 320)
                .overlay { if dropTargeted { DropOverlay() } }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    for pr in providers {
                        _ = pr.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            Task { @MainActor in copyIn(url, to: p) }
                        }
                    }
                    return true
                }
            }
            .quickLookPreview($preview, in: files.map { p.folderURL.appendingPathComponent($0) })
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { urls.forEach { copyIn($0, to: p) } }
            }
            .onAppear(perform: reload)
            .navigationTitle(p.name)
        }
    }

    private func reload() {
        guard let i = index else { return }
        files = ProjectFiles.list(app.projects[i])
    }

    private func copyIn(_ url: URL, to p: Project) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dest = p.folderURL.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.copyItem(at: url, to: dest)
        reload()
    }
}
