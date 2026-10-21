import Foundation

// MARK: - Providers & model references

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case local, google, groq, openrouter, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "On this Mac"
        case .google: return "Google AI Studio"
        case .groq: return "Groq"
        case .openrouter: return "OpenRouter"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var symbol: String {
        switch self {
        case .local: return "desktopcomputer"
        case .google: return "sparkle"
        case .groq: return "bolt.fill"
        case .openrouter: return "arrow.triangle.branch"
        case .custom: return "server.rack"
        }
    }

    var baseURL: String {
        switch self {
        case .local: return "http://127.0.0.1:\(LocalEngine.port)/v1"
        case .google: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return AppSettings.shared.customBaseURL
        }
    }

    /// Where the user signs in to create a key.
    var keyPageURL: URL? {
        switch self {
        case .google: return URL(string: "https://aistudio.google.com/apikey")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")
        default: return nil
        }
    }

    var usagePageURL: URL? {
        switch self {
        case .google: return URL(string: "https://aistudio.google.com/usage")
        case .groq: return URL(string: "https://console.groq.com/settings/limits")
        case .openrouter: return URL(string: "https://openrouter.ai/activity")
        default: return nil
        }
    }

    var freeTierNote: String {
        switch self {
        case .google: return "Free tier with per-minute and per-day request limits per model."
        case .groq: return "Free tier, very fast. Limits are reported live with every reply."
        case .openrouter: return "Models ending in “:free” cost nothing (about 50 requests/day without credits)."
        case .custom: return "Any server that speaks the OpenAI chat API."
        case .local: return "Runs privately on your Mac. No key, no limits."
        }
    }

    var needsKey: Bool { self != .local }
}

struct ModelRef: Codable, Hashable, Identifiable {
    var provider: ProviderID
    var id: String
    var name: String
    var vision: Bool = false

    var qualifiedID: String { "\(provider.rawValue)/\(id)" }
}

// MARK: - Arbitrary JSON

enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    init?(any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let a as [Any]: self = .array(a.compactMap { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.compactMapValues { JSONValue(any: $0) })
        case is NSNull: self = .null
        default: return nil
        }
    }

    var any: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues { $0.any }
        case .array(let a): return a.map { $0.any }
        case .null: return NSNull()
        }
    }
}

// MARK: - Chats

enum ThinkLevel: String, Codable, CaseIterable, Identifiable {
    case off, standard, high, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Fast"
        case .standard: return "Normal"
        case .high: return "Think hard"
        case .max: return "Think harder"
        }
    }
    var symbol: String {
        switch self {
        case .off: return "hare"
        case .standard: return "brain"
        case .high: return "brain.head.profile"
        case .max: return "brain.filled.head.profile"
        }
    }
    var help: String {
        switch self {
        case .off: return "No extra reasoning. Quickest answers."
        case .standard: return "The model decides how much to think."
        case .high: return "Maximum reasoning budget and step-by-step instructions."
        case .max: return "Think hard, then a second pass reviews and corrects the answer."
        }
    }
}

struct Capabilities: Codable, Hashable {
    var webSearch = true
    var imageGeneration = false
    var computerAccess = false
    var browser = false
    var websites = false
}

struct Attachment: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case image, text, pdf, other }
    var id = UUID()
    var kind: Kind
    var filename: String
    var path: String
    var extractedText: String?
}

struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var arguments: String
    var extra: JSONValue?
}

struct ChatMessage: Codable, Hashable, Identifiable {
    enum Role: String, Codable { case system, user, assistant, tool }
    var id = UUID()
    var role: Role
    var content: String = ""
    var reasoning: String = ""             // kept for context, never shown
    var thinkingSeconds: Double?
    var status: String?                      // e.g. "Loading model…"
    var attachments: [Attachment] = []
    var toolCalls: [ToolCall] = []
    var toolCallID: String?
    var toolName: String?
    var images: [String] = []          // generated/screenshot images to show (and to send to vision models)
    var presentedFiles: [String] = []  // files the model asked to show the user
    var links: [String] = []           // e.g. localhost site URLs
    var isError = false
    var modelName: String?
    var createdAt = Date()
}

struct Chat: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = "New Chat"
    var projectID: UUID?
    var model: ModelRef?
    var messages: [ChatMessage] = []
    var capabilities = Capabilities()
    var think: ThinkLevel = .standard
    var autoApprove = false
    var createdAt = Date()
    var updatedAt = Date()
}

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var folder: String
    var instructions: String = ""
    var createdAt = Date()

    var folderURL: URL { URL(fileURLWithPath: folder) }
}

// MARK: - Local models

struct LocalModel: Codable, Identifiable, Hashable {
    enum Format: String, Codable { case gguf, mlx }
    var id: String               // e.g. "unsloth/Qwen3.5-4B-GGUF:Q4_K_M"
    var repo: String
    var format: Format
    var displayName: String
    var directory: String        // folder on disk
    var mainFile: String?        // gguf: first model file (relative to directory)
    var mmproj: String?          // gguf vision projector
    var sizeBytes: Int64
    var downloadedAt = Date()

    var vision: Bool { mmproj != nil }
    var ref: ModelRef { ModelRef(provider: .local, id: id, name: displayName, vision: vision) }
}
