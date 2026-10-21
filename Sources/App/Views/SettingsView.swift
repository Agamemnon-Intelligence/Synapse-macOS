import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var imageProvider = AppSettings.shared.imageProvider
    @State private var geminiImageModel = AppSettings.shared.geminiImageModel
    @State private var contextSize = AppSettings.shared.contextSize
    @State private var systemPrompt = AppSettings.shared.systemPrompt
    @State private var apiEnabled = AppSettings.shared.apiServerEnabled
    @State private var cliResult: String?
    @State private var shellTimeout = AppSettings.shared.shellTimeout

    var body: some View {
        TabView {
            Form {
                Section("Custom instructions (all chats)") {
                    TextEditor(text: $systemPrompt).frame(height: 110).font(.body)
                        .onChange(of: systemPrompt) { _, v in app.settings.systemPrompt = v; app.settings.save() }
                }
                Section("Image generation") {
                    Picker("Provider", selection: $imageProvider) {
                        ForEach(ImageProvider.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: imageProvider) { _, v in app.settings.imageProvider = v; app.settings.save() }
                    if imageProvider == .gemini {
                        TextField("Gemini image model", text: $geminiImageModel)
                            .onChange(of: geminiImageModel) { _, v in app.settings.geminiImageModel = v; app.settings.save() }
                        Text("Image models may not be included in the free tier.").font(.caption).foregroundStyle(.secondary)
                    }
                    if imageProvider == .local {
                        Text("Install mflux in Terminal with `uv tool install mflux`. FLUX needs 16 GB+ RAM.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Computer access") {
                    Stepper("Shell command timeout: \(Int(shellTimeout)) s", value: $shellTimeout, in: 10...1800, step: 10)
                        .onChange(of: shellTimeout) { _, v in app.settings.shellTimeout = v; app.settings.save() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Local models") {
                    Picker("Context length", selection: $contextSize) {
                        ForEach([4096, 8192, 16384, 32768, 65536], id: \.self) { Text("\($0.formatted()) tokens").tag($0) }
                    }
                    .onChange(of: contextSize) { _, v in app.settings.contextSize = v; app.settings.save(); app.engine.stop() }
                    Text("Longer context uses more memory. 8K is a good default on 8 GB Macs.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Models", systemImage: "cpu") }

            Form {
                Section("Terminal") {
                    Text("Use any model from Terminal: `synapse chat`, `synapse models`, `synapse run <model> \"prompt\"`.")
                    Button("Install `synapse` Command") { cliResult = app.installCLI() }
                    if let cliResult { Text(cliResult).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Section("Local API server") {
                    Toggle("Serve all models on http://127.0.0.1:\(app.settings.apiServerPort)/v1", isOn: $apiEnabled)
                        .onChange(of: apiEnabled) { _, v in app.settings.apiServerEnabled = v; app.settings.save(); app.startAPIServer() }
                    Text("OpenAI-compatible. Point other apps (editors, scripts) here to use your local and cloud models. Only reachable from this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Terminal & API", systemImage: "terminal") }

            VStack(spacing: 12) {
                SynapseLogo(size: 96)
                Text("Synapse").font(.title.bold())
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .foregroundStyle(.secondary)
                Text("Run AI models locally or through free APIs.\nCopyright © 2026 Miraz Bakis · MIT License").multilineTextAlignment(.center).font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
    }
}
