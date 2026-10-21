import SwiftUI

@MainActor
@Observable
final class CatalogStore {
    static let shared = CatalogStore()
    var variants: [String: [ModelVariant]] = [:]
    var errors: [String: String] = [:]
    private var loading: Set<String> = []

    func load(_ repo: String) async {
        guard variants[repo] == nil, !loading.contains(repo) else { return }
        loading.insert(repo)
        defer { loading.remove(repo) }
        do { variants[repo] = HuggingFace.variants(repo: repo, files: try await HuggingFace.files(of: repo)) }
        catch { errors[repo] = error.localizedDescription }
    }

    func loadAll() async {
        await withTaskGroup(of: Void.self) { g in
            for e in Catalog.entries { g.addTask { await self.load(e.repo) } }
        }
    }

    func recommended(_ e: CatalogEntry) -> ModelVariant? { variants[e.repo].flatMap { HuggingFace.recommendedVariant($0) } }
}

struct ModelsView: View {
    enum Tab: String, CaseIterable { case recommended = "Recommended", search = "Search HuggingFace", mine = "My Models", cloud = "Cloud Models", engines = "Engines" }
    @Environment(AppState.self) private var app
    @State private var tab: Tab = .recommended

    var body: some View {
        VStack(spacing: 0) {
            HardwareBanner()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.bottom, 14)
            Divider()
            switch tab {
            case .recommended: RecommendedList()
            case .search: HFSearchView()
            case .mine: MyModelsView()
            case .cloud: CloudModelsView()
            case .engines: EnginesView()
            }
        }
        .navigationTitle("Models")
    }
}

struct HardwareBanner: View {
    let hw = HardwareInfo.current
    var body: some View {
        PageHeader(title: "Models",
                   subtitle: "\(hw.chip) · \(Int(hw.memoryGB.rounded())) GB memory · \(formatBytes(hw.freeDiskBytes)) free. \(advice)") {
            EmptyView()
        }
    }

    var advice: String {
        switch hw.memoryGB {
        case ..<10: return "Small models (up to ~4B) run best."
        case ..<20: return "Models up to ~12B run well."
        case ..<40: return "Models up to ~30B run well."
        default: return "Large models run well."
        }
    }
}

struct FitBadge: View {
    let fit: HardwareInfo.Fit
    var body: some View {
        let color: Color = fit == .great ? .green : fit == .good ? .mint : fit == .tight ? .orange : .red
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(fit.label).font(.caption).foregroundStyle(.secondary)
        }
        .help(fit.detail)
    }
}

struct TagChip: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fill))
    }
}

struct RecommendedList: View {
    @Environment(AppState.self) private var app
    @State private var store = CatalogStore.shared
    @State private var showMLX = HardwareInfo.current.isAppleSilicon

    var body: some View {
        let hw = HardwareInfo.current
        let entries = Catalog.entries.filter { $0.format == .gguf || showMLX }
        let scored = entries.map { e -> (CatalogEntry, ModelVariant?, HardwareInfo.Fit) in
            let v = store.recommended(e)
            return (e, v, v.map { hw.fit(forModelBytes: $0.sizeBytes) } ?? .good)
        }
        let fitting = scored.filter { $0.2 <= .good }.sorted { ($0.1?.sizeBytes ?? 0) > ($1.1?.sizeBytes ?? 0) }
        let best = fitting.first { $0.0.format == .gguf }?.0.repo
        let ordered = scored.sorted { a, b in
            if a.2 != b.2 { return a.2 < b.2 }
            if a.0.repo == best { return true }
            if b.0.repo == best { return false }
            return (a.1?.sizeBytes ?? 0) > (b.1?.sizeBytes ?? 0)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Sorted by how well they run on this Mac.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if HardwareInfo.current.isAppleSilicon { Toggle("Show MLX models", isOn: $showMLX).toggleStyle(.switch).controlSize(.small) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                    ForEach(ordered, id: \.0.repo) { e, v, fit in
                        CatalogCard(entry: e, variant: v, fit: fit, isBest: e.repo == best, error: store.errors[e.repo])
                    }
                }
            }
            .padding(28)
        }
        .task { await store.loadAll() }
    }
}

struct CatalogCard: View {
    @Environment(AppState.self) private var app
    let entry: CatalogEntry
    let variant: ModelVariant?
    let fit: HardwareInfo.Fit
    let isBest: Bool
    let error: String?
    @State private var showVariants = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.title).font(.headline)
                if isBest {
                    Text("Recommended").font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                }
                Spacer()
                Text(entry.format == .gguf ? "GGUF" : "MLX").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Text(entry.blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(entry.tags, id: \.self) { TagChip(text: $0) }
                Spacer()
            }
            Divider()
            HStack {
                if let variant {
                    FitBadge(fit: fit)
                    Text("\(variant.label) · \(formatBytes(variant.sizeBytes))").font(.caption).foregroundStyle(.secondary)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let variant { DownloadButton(variant: variant, displayName: entry.title) }
                Button { showVariants = true } label: { Image(systemName: "ellipsis") }.buttonStyle(.borderless)
                    .help("Other sizes/quantizations")
            }
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: isBest ? Theme.accent.opacity(0.18) : nil)
        .opacity(fit == .tooLarge ? 0.6 : 1)
        .sheet(isPresented: $showVariants) { VariantsSheet(repo: entry.repo, title: entry.title) }
    }
}

struct DownloadButton: View {
    @Environment(AppState.self) private var app
    let variant: ModelVariant
    let displayName: String

    var body: some View {
        if let m = app.localModel(variant.id) {
            Button { chat(with: m) } label: { Label("Chat", systemImage: "bubble.left.fill") }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
        } else if let item = app.downloads.items[variant.id] {
            if let err = item.error {
                HStack {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1).frame(maxWidth: 120)
                    Button("Retry") { app.downloads.cancel(variant.id); app.downloads.start(variant, displayName: displayName) }.controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView(value: item.fraction).frame(width: 90)
                    Text("\(Int(item.fraction * 100))%").font(.caption.monospacedDigit())
                    Button { app.downloads.cancel(variant.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
            }
        } else {
            Button { app.downloads.start(variant, displayName: displayName) } label: { Label("Download", systemImage: "arrow.down.circle") }
                .controlSize(.small)
                .disabled(Int64(Double(variant.sizeBytes) * 1.05) > HardwareInfo.current.freeDiskBytes)
        }
    }

    private func chat(with m: LocalModel) {
        let id = app.newChat()
        if let i = app.chatIndex(id) { app.chats[i].model = m.ref }
    }
}

struct VariantsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = CatalogStore.shared
    let repo: String
    let title: String

    var body: some View {
        let hw = HardwareInfo.current
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Link(repo, destination: URL(string: "https://huggingface.co/\(repo)")!).font(.caption)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Smaller quantizations use less memory but lose some quality. Q4_K_M is the usual sweet spot.")
                .font(.callout).foregroundStyle(.secondary)
            if let list = store.variants[repo] {
                if list.isEmpty { Text("No GGUF or MLX files found in this repo.").foregroundStyle(.secondary) }
                List(list) { v in
                    HStack {
                        Text(v.label).font(.body.monospaced()).frame(width: 130, alignment: .leading)
                        Text(formatBytes(v.sizeBytes)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        FitBadge(fit: hw.fit(forModelBytes: v.sizeBytes))
                        if v.mmproj != nil { Image(systemName: "eye").help("Includes vision") }
                        if v.files.count > 1 && v.format == .gguf { Text("\(v.files.count) parts").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        DownloadButton(variant: v, displayName: title)
                    }
                }
                .frame(minHeight: 280)
            } else if let e = store.errors[repo] {
                Text(e).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
        .task { await store.load(repo) }
    }
}

struct HFSearchView: View {
    @State private var query = ""
    @State private var format: LocalModel.Format = .gguf
    @State private var results: [HFModelSummary] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selected: HFModelSummary?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search HuggingFace (e.g. qwen, llama, gemma, coder, mistral)", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await search() } }
                Picker("", selection: $format) {
                    Text("GGUF (llama.cpp)").tag(LocalModel.Format.gguf)
                    if HardwareInfo.current.isAppleSilicon { Text("MLX").tag(LocalModel.Format.mlx) }
                }
                .labelsHidden().frame(width: 170)
                .onChange(of: format) { _, _ in Task { await search() } }
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .glass(Capsule())
            .padding(.horizontal, 28).padding(.vertical, 12)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 24) }
            List(results) { r in
                Button { selected = r } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).fontWeight(.medium)
                            Text(r.author).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let tag = r.pipeline_tag { TagChip(text: tag) }
                        Label("\(compact(r.downloads ?? 0))", systemImage: "arrow.down").font(.caption).foregroundStyle(.secondary)
                        Label("\(compact(r.likes ?? 0))", systemImage: "heart").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
        .sheet(item: $selected) { r in VariantsSheet(repo: r.id, title: r.name) }
        .task { if results.isEmpty { await search() } }
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }

    private func search() async {
        loading = true
        defer { loading = false }
        do { results = try await HuggingFace.search(query, format: format); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct MyModelsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.localModels.isEmpty && app.downloads.items.isEmpty {
            ContentUnavailableView("No local models yet", systemImage: "square.stack.3d.down.right",
                                   description: Text("Download one from Recommended. Models run privately on your Mac."))
        } else {
            List {
                if !app.downloads.items.isEmpty {
                    Section("Downloading") {
                        ForEach(Array(app.downloads.items.values).filter { !$0.done }) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.displayName + " · " + item.variant.label).fontWeight(.medium)
                                    Text(item.error ?? item.currentFile).font(.caption).foregroundStyle(item.error == nil ? Color.secondary : Color.red).lineLimit(1)
                                }
                                Spacer()
                                Text("\(formatBytes(item.received)) / \(formatBytes(item.variant.sizeBytes))").font(.caption.monospacedDigit())
                                ProgressView(value: item.fraction).frame(width: 120)
                                Button { app.downloads.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("On this Mac") {
                    ForEach(app.localModels) { m in
                        HStack(spacing: 12) {
                            Image(systemName: "cpu").font(.title3).foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(m.displayName).fontWeight(.medium)
                                Text("\(m.format == .gguf ? "GGUF · llama.cpp" : "MLX") · \(formatBytes(m.sizeBytes)) · \(m.repo)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            FitBadge(fit: HardwareInfo.current.fit(forModelBytes: m.sizeBytes))
                            if app.engine.loadedModelID == m.id {
                                Button("Unload") { app.engine.stop() }
                            } else {
                                Button("Load") { Task { try? await app.loadLocal(m) } }
                            }
                            Button {
                                let id = app.newChat()
                                if let i = app.chatIndex(id) { app.chats[i].model = m.ref }
                            } label: { Label("Chat", systemImage: "bubble.left.fill") }
                                .buttonStyle(.borderedProminent).tint(Theme.accent)
                            Button { openInTerminal(command: "synapse chat \"\(m.ref.qualifiedID)\"") } label: { Image(systemName: "terminal") }
                                .help("Chat in Terminal")
                            Menu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.directory)]) }
                                Button("Set as Default Model") { app.settings.defaultModel = m.ref; app.settings.save() }
                                Divider()
                                Button("Delete", role: .destructive) { app.deleteLocalModel(m) }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

struct CloudModelsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        List {
            ForEach([ProviderID.google, .groq, .openrouter, .custom], id: \.self) { p in
                Section {
                    if p == .custom ? !app.settings.customEnabled : !app.hasKey(p) {
                        HStack {
                            Text(p.freeTierNote).foregroundStyle(.secondary)
                            Spacer()
                            Button(p == .custom ? "Set Up…" : "Sign In & Add Key…") { app.showKeys = true }
                        }
                    } else if let err = app.remoteErrors[p] {
                        HStack {
                            Text(err).foregroundStyle(.red).lineLimit(3)
                            Spacer()
                            Button("Retry") { Task { await app.refreshRemoteModels(only: p) } }
                        }
                    } else if let list = app.remoteModels[p] {
                        ForEach(list) { m in
                            HStack {
                                Text(m.name)
                                if m.vision { Image(systemName: "eye").foregroundStyle(.secondary).help("Understands images") }
                                Spacer()
                                Button { openInTerminal(command: "synapse chat \"\(m.qualifiedID)\"") } label: { Image(systemName: "terminal") }
                                    .buttonStyle(.borderless).help("Chat in Terminal")
                                Button("Default") { app.settings.defaultModel = m; app.settings.save() }.buttonStyle(.borderless)
                                    .foregroundStyle(app.settings.defaultModel == m ? Theme.accent : .secondary)
                                Button("Chat") {
                                    let id = app.newChat()
                                    if let i = app.chatIndex(id) { app.chats[i].model = m }
                                }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                } header: {
                    HStack {
                        Label(p.displayName, systemImage: p.symbol)
                        Spacer()
                        if let url = p.usagePageURL { Link("Dashboard", destination: url).font(.caption) }
                    }
                }
            }
        }
    }
}

struct EnginesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let e = app.engine
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                engineRow(title: "llama.cpp", subtitle: "Runs GGUF models. Works on every Mac and supports vision models.",
                          installed: e.llamaServerPath != nil, path: e.llamaServerPath) { await e.installLlama() }
                if HardwareInfo.current.isAppleSilicon {
                    engineRow(title: "MLX", subtitle: "Apple's framework for M-series chips. Often the fastest option.",
                              installed: e.mlxPython != nil, path: e.mlxPython) { await e.installMLX() }
                }
                if !e.installLog.isEmpty || e.installing {
                    GroupBox("Install log") {
                        ScrollView { Text(e.installLog).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(height: 180)
                    }
                }
                GroupBox("Engine log") {
                    ScrollView { Text(e.log.isEmpty ? "No model loaded." : e.log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 200)
                }
                Text("Local models are served on http://127.0.0.1:\(LocalEngine.port)/v1. Synapse also exposes every model (local and cloud) on http://127.0.0.1:\(app.settings.apiServerPort)/v1 for the `synapse` command and other apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func engineRow(title: String, subtitle: String, installed: Bool, path: String?, install: @escaping () async -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title).foregroundStyle(installed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).foregroundStyle(.secondary).font(.callout)
                if let path { Text(path).font(.caption.monospaced()).foregroundStyle(.tertiary) }
            }
            Spacer()
            Button(installed ? "Update" : "Install") { Task { await install() } }
                .buttonStyle(.borderedProminent).tint(installed ? .gray : Theme.accent)
                .disabled(app.engine.installing)
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
