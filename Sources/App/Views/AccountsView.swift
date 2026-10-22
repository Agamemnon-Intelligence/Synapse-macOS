import SwiftUI

struct AccountsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts & API Keys").font(.headline)
                    Text("Sign in to a provider, create a free key, and paste it here. Keys are stored in your macOS Keychain.")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    ProviderKeyRow(provider: .google, steps: "Sign in with your Google account → “Create API key” → copy it.")
                    ProviderKeyRow(provider: .groq, steps: "Sign in (Google, GitHub or email) → “Create API Key” → copy it.")
                    ProviderKeyRow(provider: .anthropic, steps: "Sign in to the Claude Console → “Create Key” → copy it. Paid; uses your own credits.")
                    ProviderKeyRow(provider: .deepseek, steps: "Sign in to the DeepSeek platform → “Create new API key” → copy it.")
                    ProviderKeyRow(provider: .openrouter, steps: "Sign in → “Create Key” → copy it. Free models end in “:free”.")
                    CustomProviderRow()
                    HuggingFaceTokenRow()
                }
                .padding(20)
            }
        }
        .frame(width: 680, height: 640)
    }
}

struct ProviderKeyRow: View {
    @Environment(AppState.self) private var app
    let provider: ProviderID
    let steps: String
    @State private var key = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false
    @State private var editing = false

    var body: some View {
        let hasKey = app.hasKey(provider)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: provider.symbol).font(.body).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.headline)
                    Text(provider.freeTierNote).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if hasKey {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.callout)
                    Text("\(app.remoteModels[provider]?.count ?? 0) models").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !hasKey || editing {
                HStack {
                    if let url = provider.keyPageURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: { Label("Sign In & Get Key", systemImage: "person.badge.key") }
                        .buttonStyle(.borderedProminent)
                    }
                    Text(steps).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    SecureField("Paste your \(provider.displayName) API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) { key = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                }
            } else {
                HStack {
                    Button("Test") { Task { await test() } }
                    Button("Replace Key") { editing = true }
                    if let url = provider.usagePageURL { Link("Open dashboard", destination: url) }
                    Spacer()
                    Button("Sign Out", role: .destructive) { app.setKey(nil, for: provider); result = nil }
                }
            }
            if testing { ProgressView().controlSize(.small) }
            if let result { Text(result).font(.caption).foregroundStyle(ok ? .green : .red).textSelection(.enabled) }
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        app.setKey(k, for: provider)
        key = ""
        editing = false
        Task { await test() }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let models = try await ChatClient.listModels(provider: provider)
            ok = true
            result = "Key works · \(models.count) chat models available"
            await app.refreshRemoteModels(only: provider)
        } catch {
            ok = false
            result = error.localizedDescription
        }
    }
}

struct CustomProviderRow: View {
    @Environment(AppState.self) private var app
    @State private var url = AppSettings.shared.customBaseURL
    @State private var key = ""
    @State private var enabled = AppSettings.shared.customEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: ProviderID.custom.symbol).font(.body).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom server").font(.headline)
                    Text("OpenAI, Mistral, Together, LM Studio, Ollama (http://localhost:11434/v1), or any OpenAI-compatible endpoint.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
            }
            if enabled {
                HStack {
                    TextField("Base URL (ends in /v1)", text: $url).textFieldStyle(.roundedBorder)
                    SecureField(app.hasKey(.custom) ? "Key saved (leave blank to keep)" : "API key (optional)", text: $key).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        app.settings.customBaseURL = url
                        app.settings.customEnabled = true
                        app.settings.save()
                        if !key.isEmpty { app.setKey(key, for: .custom); key = "" }
                        Task { await app.refreshRemoteModels(only: .custom) }
                    }
                }
                if let e = app.remoteErrors[.custom] { Text(e).font(.caption).foregroundStyle(.red) }
                else if let n = app.remoteModels[.custom]?.count { Text("\(n) models").font(.caption).foregroundStyle(.green) }
            }
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: enabled) { _, on in
            app.settings.customEnabled = on
            app.settings.save()
            Task { await app.refreshRemoteModels(only: .custom) }
        }
    }
}

struct HuggingFaceTokenRow: View {
    @Environment(AppState.self) private var app
    @State private var token = ""

    var body: some View {
        let has = Keychain.get("huggingface") != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "face.smiling").font(.body).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HuggingFace (optional)").font(.headline)
                    Text("Only needed for gated models (e.g. some Llama and Gemma repos) and faster downloads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if has { Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.callout) }
            }
            HStack {
                Button { NSWorkspace.shared.open(URL(string: "https://huggingface.co/settings/tokens")!) } label: {
                    Label("Sign In & Get Token", systemImage: "person.badge.key")
                }
                SecureField(has ? "Token saved" : "hf_…", text: $token).textFieldStyle(.roundedBorder)
                Button("Save") { Keychain.set(token, for: "huggingface"); token = ""; app.keysVersion += 1 }.disabled(token.isEmpty)
                if has { Button("Remove", role: .destructive) { Keychain.set(nil, for: "huggingface"); app.keysVersion += 1 } }
            }
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .id(app.keysVersion)
    }
}
