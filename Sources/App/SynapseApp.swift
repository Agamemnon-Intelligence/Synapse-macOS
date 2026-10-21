import SwiftUI

@main
struct SynapseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        Window("Synapse", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { delegate.app = app }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { app.newChat() }.keyboardShortcut("n")
                Button("New Chat in Project…") {
                    if case .project(let id) = app.selection { app.newChat(project: id) } else { app.newChat() }
                }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Synapse") {
                Button("Accounts & API Keys…") { app.showKeys = true }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Models") { app.selection = .models }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Toggle Browser") { app.showBrowserPanel.toggle() }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Usage & Limits") { app.selection = .usage }.keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("Unload Local Model") { app.engine.stop() }
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            app?.engine.stop()
            app?.save()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    override init() {
        // Always open the main window at launch instead of restoring a "no windows" state.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        super.init()
    }
}
