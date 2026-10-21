import Foundation
import Observation

/// Hosts the static websites the AI (or you) build, each on its own localhost port.
@MainActor
@Observable
final class SiteManager {
    struct Site: Identifiable, Hashable {
        var id: String { folder.path }
        let name: String
        let folder: URL
        var port: UInt16?
        var url: URL? { port.map { URL(string: "http://localhost:\($0)/")! } }
    }

    var sites: [Site] = []
    private var servers: [String: HTTPServer] = [:]
    private var nextPort: UInt16 = 5500

    init() { refresh() }

    func refresh() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Paths.sites, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let found = dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        var updated: [Site] = []
        for d in found {
            let port = sites.first { $0.folder == d }?.port
            updated.append(Site(name: d.lastPathComponent, folder: d, port: port))
        }
        // Keep running sites that live elsewhere (e.g. inside a project folder).
        for s in sites where s.port != nil && !updated.contains(where: { $0.folder == s.folder }) { updated.append(s) }
        sites = updated
    }

    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-").prefix(48).description.ifEmpty("site")
    }

    /// Writes files for a site and starts serving it.
    func create(name: String, files: [(path: String, content: String)], in parent: URL? = nil) throws -> Site {
        let folder = (parent ?? Paths.sites).appendingPathComponent(Self.slug(name), isDirectory: true)
        for f in files {
            let rel = f.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let dest = folder.appendingPathComponent(rel).standardizedFileURL
            guard dest.path.hasPrefix(folder.standardizedFileURL.path) else { continue }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.content.write(to: dest, atomically: true, encoding: .utf8)
        }
        refresh()
        return try start(folder: folder)
    }

    @discardableResult
    func start(folder: URL) throws -> Site {
        if let existing = sites.first(where: { $0.folder == folder && $0.port != nil }) { return existing }
        var lastError: Error?
        for _ in 0..<50 {
            let port = nextPort
            nextPort += 1
            let server = HTTPServer(port: port, handler: HTTPServer.staticHandler(root: folder))
            do {
                try server.start()
                servers[folder.path] = server
                let site = Site(name: folder.lastPathComponent, folder: folder, port: port)
                if let i = sites.firstIndex(where: { $0.folder == folder }) { sites[i] = site } else { sites.append(site) }
                return site
            } catch { lastError = error }
        }
        throw lastError ?? APIError(status: 0, message: "No free port")
    }

    func stop(_ site: Site) {
        servers[site.folder.path]?.stop()
        servers[site.folder.path] = nil
        if let i = sites.firstIndex(where: { $0.folder == site.folder }) { sites[i].port = nil }
    }

    func delete(_ site: Site) {
        stop(site)
        try? FileManager.default.trashItem(at: site.folder, resultingItemURL: nil)
        refresh()
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
