import Foundation
import AppKit

// MARK: - Paths

enum Paths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synapse", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func dir(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var models: URL { dir("Models") }
    static var attachments: URL { dir("Attachments") }
    static var images: URL { dir("Images") }
    static var sites: URL { dir("Sites") }
    static var mlxVenv: URL { support.appendingPathComponent("mlx-venv", isDirectory: true) }
    static var projectsRoot: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synapse Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// Documents the AI creates outside a project (presentations etc.).
    static var files: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synapse Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var stateFile: URL { support.appendingPathComponent("state.json") }
    static var usageFile: URL { support.appendingPathComponent("usage.json") }
    static var settingsFile: URL { support.appendingPathComponent("settings.json") }
}

// MARK: - Keychain

/// API keys live in the login keychain. Access goes through Apple's `security` tool so items stay
/// readable across rebuilds (an unsigned app's identity changes every build, which would re-prompt).
enum Keychain {
    static let service = "com.athenesoftworks.synapse"
    private static var cache: [String: String] = [:]
    private static var misses: Set<String> = []
    private static let lock = NSLock()

    static func get(_ account: String) -> String? {
        lock.lock()
        if let v = cache[account] { lock.unlock(); return v }
        if misses.contains(account) { lock.unlock(); return nil }
        lock.unlock()
        let r = runProcess("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], timeout: 10)
        let value = r.status == 0 ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        lock.lock(); defer { lock.unlock() }
        if value.isEmpty { misses.insert(account); return nil }
        cache[account] = value
        return value
    }

    static func set(_ value: String?, for account: String) {
        runProcess("/usr/bin/security", ["delete-generic-password", "-s", service, "-a", account], timeout: 10)
        lock.lock()
        cache[account] = nil
        misses.insert(account)
        lock.unlock()
        guard let value, !value.isEmpty else { return }
        let r = runProcess("/usr/bin/security", ["add-generic-password", "-U", "-A", "-s", service, "-a", account,
                                                  "-l", "Synapse – \(account)", "-w", value], timeout: 10)
        if r.status == 0 {
            lock.lock()
            cache[account] = value
            misses.remove(account)
            lock.unlock()
        }
    }
}

// MARK: - Settings

enum ImageProvider: String, Codable, CaseIterable, Identifiable {
    case pollinations, gemini, local
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pollinations: return "Pollinations (free, no key)"
        case .gemini: return "Google Gemini image model (uses your AI Studio key)"
        case .local: return "On this Mac (mflux / FLUX)"
        }
    }
}

final class AppSettings: Codable {
    static let shared: AppSettings = {
        // Overlay saved values on the defaults so newly added settings don't break decoding.
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { $1 }),
              let s = try? JSONDecoder().decode(AppSettings.self, from: merged) else { return AppSettings() }
        return s
    }()

    var customBaseURL = "http://localhost:1234/v1"
    var customEnabled = false
    var imageProvider: ImageProvider = .pollinations
    var geminiImageModel = "gemini-3.1-flash-image"
    var contextSize = 8192
    var apiServerEnabled = true
    var apiServerPort: UInt16 = 11435
    var systemPrompt = ""
    var defaultModel: ModelRef?   // nil = pick the best model that works right now
    var shellTimeout: Double = 120

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Paths.settingsFile) }
    }
}

// MARK: - Hardware

struct HardwareInfo {
    let chip: String
    let memoryBytes: UInt64
    let cores: Int
    let freeDiskBytes: Int64

    var memoryGB: Double { Double(memoryBytes) / 1_073_741_824 }
    var isAppleSilicon: Bool { chip.contains("Apple") }

    static let current: HardwareInfo = {
        func sysctlString(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(cString: buf)
        }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        return HardwareInfo(chip: sysctlString("machdep.cpu.brand_string"),
                            memoryBytes: ProcessInfo.processInfo.physicalMemory,
                            cores: ProcessInfo.processInfo.activeProcessorCount,
                            freeDiskBytes: free)
    }()

    enum Fit: Int, Comparable {
        case great = 0, good, tight, tooLarge
        static func < (a: Fit, b: Fit) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .great: return "Runs great"
            case .good: return "Runs well"
            case .tight: return "Tight fit"
            case .tooLarge: return "Too large"
            }
        }
        var detail: String {
            switch self {
            case .great: return "Plenty of memory left for other apps."
            case .good: return "Fits. Close heavy apps for best speed."
            case .tight: return "May be slow or swap. Quit other apps first."
            case .tooLarge: return "Needs more memory than this Mac has."
            }
        }
    }

    /// Estimate whether a model file of `bytes` fits in unified memory.
    func fit(forModelBytes bytes: Int64) -> Fit {
        let needGB = Double(bytes) / 1_073_741_824 * 1.1 + 0.9   // weights + KV cache/context + runtime
        let ratio = needGB / memoryGB
        if ratio <= 0.5 { return .great }
        if ratio <= 0.72 { return .good }
        if ratio <= 0.9 { return .tight }
        return .tooLarge
    }
}

// MARK: - Helpers

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

extension String {
    func truncated(_ n: Int) -> String {
        count > n ? String(prefix(n)) + "\n…[truncated \(count - n) characters]" : self
    }
}

/// Run a command and capture output (blocking; call off the main thread).
@discardableResult
func runProcess(_ launchPath: String, _ args: [String], cwd: URL? = nil, timeout: Double = 120,
                env: [String: String]? = nil) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
    if let env { environment.merge(env) { $1 } }
    p.environment = environment
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    let collector = OutputCollector()
    pipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData) }
    do { try p.run() } catch { return (-1, "Failed to start: \(error.localizedDescription)") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    var timedOut = false
    if p.isRunning { p.terminate(); timedOut = true }
    p.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
    var out = collector.string
    if timedOut { out += "\n[timed out after \(Int(timeout))s]" }
    return (p.terminationStatus, out)
}

final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

func openInTerminal(command: String) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("synapse-\(UUID().uuidString.prefix(6)).command")
    let script = "#!/bin/zsh\nexport PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"\n\(command)\n"
    try? script.write(to: file, atomically: true, encoding: .utf8)
    chmod(file.path, 0o755)
    NSWorkspace.shared.open(file)
}
