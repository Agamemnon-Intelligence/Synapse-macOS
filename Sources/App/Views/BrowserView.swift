import SwiftUI
import WebKit

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview !== nsView { attach(to: nsView) }
    }
    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Small browser that sits beside a chat. Opens when the model starts browsing, or from the toolbar.
struct BrowserPanel: View {
    @Environment(AppState.self) private var app
    let chatID: UUID
    @State private var address = ""
    @FocusState private var editing: Bool

    var body: some View {
        let b = app.browser
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                iconButton("chevron.left", "Back", enabled: b.canGoBack) { b.webView.goBack() }
                iconButton("chevron.right", "Forward", enabled: b.canGoForward) { b.webView.goForward() }
                iconButton(b.isLoading ? "xmark" : "arrow.clockwise", b.isLoading ? "Stop" : "Reload") {
                    if b.isLoading { b.webView.stopLoading() } else { b.webView.reload() }
                }
                HStack(spacing: 6) {
                    Image(systemName: b.url.hasPrefix("https") ? "lock.fill" : "globe")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    TextField("Search or enter address", text: $address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($editing)
                        .onSubmit { b.load(address) }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Theme.fill, in: Capsule())
                Menu {
                    Button("Open in Default Browser") { if let u = b.webView.url { NSWorkspace.shared.open(u) } }
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(b.url, forType: .string)
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                iconButton("xmark", "Close browser") { app.showBrowserPanel = false }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .glass(Capsule())
            .padding(8)

            if b.agentActive && app.generating.contains(chatID) {
                HStack(spacing: 8) {
                    PulsingDot()
                    Text("Synapse is using the browser" + (b.lastAgentAction.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Take Over") { app.stop(chatID) }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glass(Capsule(), tint: Theme.accent.opacity(0.2))
                .padding(.horizontal, 8).padding(.bottom, 6)
            }
            ZStack {
                WebViewHost(webView: b.webView)
                if b.url.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "globe").font(.system(size: 22)).foregroundStyle(.tertiary)
                        Text("Turn on Browser in a chat and the model can browse here.").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                }
            }
        }
        .onAppear { address = b.url }
        .onChange(of: b.url) { _, new in if !editing { address = new } }
    }

    private func iconButton(_ icon: String, _ help: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}

struct PulsingDot: View {
    var body: some View {
        TimelineView(.animation) { t in
            let p = (sin(t.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
            Circle().fill(Theme.accent).frame(width: 7, height: 7).opacity(0.4 + 0.6 * p)
        }
    }
}

struct SitesView: View {
    @Environment(AppState.self) private var app
    @State private var error: String?

    var body: some View {
        let sites = app.sites
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Websites", subtitle: "Sites your models build are hosted on localhost while Synapse is open.") {
                Button { sites.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button("Open Folder") { NSWorkspace.shared.open(Paths.sites) }
                Button("New Site") {
                    let id = app.newChat()
                    if let i = app.chatIndex(id) { app.chats[i].capabilities.websites = true }
                }
                .buttonStyle(.borderedProminent)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 28) }
            if sites.sites.isEmpty {
                ContentUnavailableView("No websites yet", systemImage: "globe",
                                       description: Text("Turn on Websites in a chat and ask for a site."))
            } else {
                List(sites.sites) { site in
                    HStack(spacing: 12) {
                        Circle().fill(site.port != nil ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name).fontWeight(.medium)
                            Text(site.url?.absoluteString ?? "Stopped").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = site.url {
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Stop") { sites.stop(site) }
                        } else {
                            Button("Start") {
                                do { try sites.start(folder: site.folder) } catch { self.error = error.localizedDescription }
                            }
                        }
                        Menu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) }
                            Button("Move to Trash", role: .destructive) { sites.delete(site) }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Websites")
    }
}

/// Shared header for full-page views.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) { actions }
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 16)
    }
}
