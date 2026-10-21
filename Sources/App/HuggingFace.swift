import Foundation
import Observation

struct HFModelSummary: Identifiable, Hashable, Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let pipeline_tag: String?
    let tags: [String]?

    var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
}

struct HFFile: Hashable, Decodable {
    let type: String
    let path: String
    let size: Int64?
}

/// One downloadable variant of a repo (a GGUF quant, or a whole MLX repo).
struct ModelVariant: Identifiable, Hashable {
    var id: String { repo + ":" + label }
    let repo: String
    let format: LocalModel.Format
    let label: String          // e.g. "Q4_K_M" or "MLX 4-bit"
    let files: [String]        // files to download (gguf parts or every MLX file)
    let mmproj: String?
    let sizeBytes: Int64

    var mainFile: String? { format == .gguf ? files.sorted().first : nil }
}

enum HuggingFace {
    static let base = "https://huggingface.co"

    static func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: base + path)!)
        if let token = Keychain.get("huggingface") { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    static func search(_ query: String, format: LocalModel.Format, limit: Int = 40) async throws -> [HFModelSummary] {
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: format == .gguf ? "filter" : "library", value: format == .gguf ? "gguf" : "mlx"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let (data, _) = try await URLSession.shared.data(for: request("/api/models" + (comps.string ?? "")))
        return try JSONDecoder().decode([HFModelSummary].self, from: data)
            .filter { m in
                let l = m.id.lowercased()
                // Hide things that aren't chat models.
                return !["embed", "whisper", "tts", "asr", "parakeet", "rerank", "-image", "kokoro", "music", "audio"].contains { l.contains($0) }
            }
    }

    static func files(of repo: String) async throws -> [HFFile] {
        let (data, resp) = try await URLSession.shared.data(for: request("/api/models/\(repo)/tree/main?recursive=true"))
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw APIError(status: http.statusCode, message: "This model is gated. Accept its license on huggingface.co and add a HuggingFace token in Accounts.")
        }
        return try JSONDecoder().decode([HFFile].self, from: data).filter { $0.type == "file" }
    }

    /// Turns a repo's file list into downloadable variants.
    static func variants(repo: String, files: [HFFile]) -> [ModelVariant] {
        let ggufs = files.filter { $0.path.lowercased().hasSuffix(".gguf") }
        if !ggufs.isEmpty {
            let mmproj = ggufs.filter { $0.path.lowercased().contains("mmproj") }
                .sorted { ($0.path.contains("F16") ? 0 : 1) < ($1.path.contains("F16") ? 0 : 1) }.first
            let weights = ggufs.filter { !$0.path.lowercased().contains("mmproj") && !$0.path.lowercased().contains("mtp-") }
            // Group split files (…-00001-of-00003.gguf) into one variant.
            var groups: [String: [HFFile]] = [:]
            for f in weights {
                let key = f.path.replacingOccurrences(of: #"-\d{5}-of-\d{5}\.gguf$"#, with: ".gguf", options: .regularExpression)
                groups[key, default: []].append(f)
            }
            return groups.map { key, parts in
                let size = parts.reduce(0) { $0 + ($1.size ?? 0) } + (mmproj?.size ?? 0)
                return ModelVariant(repo: repo, format: .gguf, label: quantLabel(key), files: parts.map(\.path).sorted(),
                                    mmproj: mmproj?.path, sizeBytes: size)
            }.sorted { $0.sizeBytes < $1.sizeBytes }
        }
        let hasSafetensors = files.contains { $0.path.hasSuffix(".safetensors") }
        guard hasSafetensors else { return [] }
        let keep = files.filter { !$0.path.hasPrefix(".") && !$0.path.lowercased().hasSuffix(".md") }
        let size = keep.reduce(0) { $0 + ($1.size ?? 0) }
        let label = repo.lowercased().contains("8bit") ? "MLX 8-bit" : repo.lowercased().contains("4bit") ? "MLX 4-bit" : "MLX"
        return [ModelVariant(repo: repo, format: .mlx, label: label, files: keep.map(\.path), mmproj: nil, sizeBytes: size)]
    }

    static func quantLabel(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".gguf", with: "")
        if let r = name.range(of: #"(UD-)?(I?Q\d[\w]*|BF16|F16|F32|MXFP4\w*)$"#, options: [.regularExpression, .caseInsensitive]) {
            return String(name[r])
        }
        return name
    }

    /// Picks the best variant for this Mac: the highest-quality quant that still fits comfortably.
    static func recommendedVariant(_ variants: [ModelVariant], hw: HardwareInfo = .current) -> ModelVariant? {
        let preferred = ["Q4_K_M", "UD-Q4_K_XL", "Q4_K_S", "IQ4_XS", "Q5_K_M", "Q6_K", "Q8_0", "MXFP4", "F16"]
        let fitting = variants.filter { hw.fit(forModelBytes: $0.sizeBytes) <= .good }
        for p in preferred { if let v = fitting.first(where: { $0.label.uppercased() == p.uppercased() }) { return v } }
        if let v = fitting.last { return v }
        for p in preferred { if let v = variants.first(where: { $0.label.uppercased() == p.uppercased() }) { return v } }
        return variants.first
    }
}

// MARK: - Curated catalog

struct CatalogEntry: Identifiable, Hashable {
    var id: String { repo }
    let repo: String
    let title: String
    let blurb: String
    let tags: [String]
    let format: LocalModel.Format
}

enum Catalog {
    static let entries: [CatalogEntry] = [
        .init(repo: "unsloth/Qwen3.5-0.8B-GGUF", title: "Qwen3.5 0.8B", blurb: "Tiny and instant. Good for quick questions on any Mac.", tags: ["fast"], format: .gguf),
        .init(repo: "unsloth/Qwen3.5-2B-GGUF", title: "Qwen3.5 2B", blurb: "Small, quick all-rounder with thinking mode.", tags: ["fast", "reasoning"], format: .gguf),
        .init(repo: "unsloth/gemma-4-E2B-it-GGUF", title: "Gemma 4 E2B", blurb: "Google's efficient small model. Sees images.", tags: ["vision", "fast"], format: .gguf),
        .init(repo: "unsloth/Llama-3.2-3B-Instruct-GGUF", title: "Llama 3.2 3B", blurb: "Meta's compact chat model. Reliable tool use.", tags: ["tools"], format: .gguf),
        .init(repo: "unsloth/Phi-4-mini-instruct-GGUF", title: "Phi-4 mini", blurb: "Microsoft's small model, strong at math and logic.", tags: ["reasoning"], format: .gguf),
        .init(repo: "unsloth/Qwen3.5-4B-GGUF", title: "Qwen3.5 4B", blurb: "Best overall pick for 8 GB Macs. Thinks, codes, sees images.", tags: ["reasoning", "coding", "vision"], format: .gguf),
        .init(repo: "unsloth/gemma-4-E4B-it-GGUF", title: "Gemma 4 E4B", blurb: "Great writing quality and vision in a small package.", tags: ["vision", "writing"], format: .gguf),
        .init(repo: "unsloth/Qwen3.5-9B-GGUF", title: "Qwen3.5 9B", blurb: "Much smarter. Needs 16 GB for comfortable speed.", tags: ["reasoning", "coding", "vision"], format: .gguf),
        .init(repo: "unsloth/gemma-4-12b-it-GGUF", title: "Gemma 4 12B", blurb: "Excellent writer and image understanding.", tags: ["vision", "writing"], format: .gguf),
        .init(repo: "unsloth/gpt-oss-20b-GGUF", title: "gpt-oss 20B", blurb: "OpenAI's open-weight reasoning model.", tags: ["reasoning", "tools"], format: .gguf),
        .init(repo: "unsloth/gemma-4-26B-A4B-it-GGUF", title: "Gemma 4 26B A4B", blurb: "Mixture-of-experts: big-model quality, small-model speed.", tags: ["vision", "writing"], format: .gguf),
        .init(repo: "unsloth/Qwen3.8-27B-GGUF", title: "Qwen3.8 27B", blurb: "Top-tier open model for coding and reasoning.", tags: ["reasoning", "coding"], format: .gguf),
        .init(repo: "unsloth/Qwen3.6-35B-A3B-GGUF", title: "Qwen3.6 35B A3B", blurb: "Fast mixture-of-experts with strong tool use.", tags: ["reasoning", "coding", "tools"], format: .gguf),
        .init(repo: "unsloth/gemma-4-31B-it-GGUF", title: "Gemma 4 31B", blurb: "Google's largest open Gemma.", tags: ["vision", "writing"], format: .gguf),

        .init(repo: "mlx-community/Qwen3-0.6B-4bit", title: "Qwen3 0.6B (MLX)", blurb: "Smallest MLX model. Instant replies.", tags: ["fast"], format: .mlx),
        .init(repo: "mlx-community/Llama-3.2-3B-Instruct-4bit", title: "Llama 3.2 3B (MLX)", blurb: "Fast on Apple Silicon.", tags: ["fast"], format: .mlx),
        .init(repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", title: "Qwen3 4B Instruct (MLX)", blurb: "Strong small model, tuned for Apple GPUs.", tags: ["coding"], format: .mlx),
        .init(repo: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", title: "Qwen2.5 Coder 7B (MLX)", blurb: "Code-focused model.", tags: ["coding"], format: .mlx),
        .init(repo: "mlx-community/Qwen3-8B-4bit", title: "Qwen3 8B (MLX)", blurb: "Thinking model, good balance.", tags: ["reasoning"], format: .mlx),
        .init(repo: "mlx-community/gemma-3-12b-it-4bit", title: "Gemma 3 12B (MLX)", blurb: "Strong writer.", tags: ["writing"], format: .mlx),
        .init(repo: "mlx-community/gpt-oss-20b-MXFP4-Q8", title: "gpt-oss 20B (MLX)", blurb: "OpenAI's open reasoning model, on MLX.", tags: ["reasoning"], format: .mlx),
        .init(repo: "mlx-community/Qwen3.6-35B-A3B-4bit", title: "Qwen3.6 35B A3B (MLX)", blurb: "Fast MoE for 32 GB+ Macs.", tags: ["reasoning", "coding"], format: .mlx),
    ]
}

// MARK: - Downloads

@MainActor
@Observable
final class DownloadManager: NSObject {
    struct Item: Identifiable {
        let id: String
        let variant: ModelVariant
        let displayName: String
        var received: Int64 = 0
        var currentFile = ""
        var error: String?
        var done = false
        var fraction: Double { variant.sizeBytes > 0 ? min(1, Double(received) / Double(variant.sizeBytes)) : 0 }
    }

    var items: [String: Item] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    var onComplete: ((LocalModel) -> Void)?

    func isDownloading(_ variant: ModelVariant) -> Bool {
        if let i = items[variant.id] { return !i.done && i.error == nil }
        return false
    }

    func start(_ variant: ModelVariant, displayName: String) {
        guard !isDownloading(variant) else { return }
        items[variant.id] = Item(id: variant.id, variant: variant, displayName: displayName)
        tasks[variant.id] = Task { await self.run(variant, displayName: displayName) }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        items[id] = nil
    }

    private func run(_ variant: ModelVariant, displayName: String) async {
        let folderName = variant.repo.replacingOccurrences(of: "/", with: "__") + (variant.format == .gguf ? "__" + variant.label : "")
        let dir = Paths.models.appendingPathComponent(folderName, isDirectory: true)
        var all = variant.files
        if let mm = variant.mmproj { all.append(mm) }
        var completedBytes: Int64 = 0
        do {
            for file in all {
                try Task.checkCancellation()
                let dest = dir.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                items[variant.id]?.currentFile = file
                if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path), let s = attrs[.size] as? Int64, s > 0 {
                    completedBytes += s
                    items[variant.id]?.received = completedBytes
                    continue
                }
                let encoded = file.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
                let req = HuggingFace.request("/\(variant.repo)/resolve/main/\(encoded)")
                let base = completedBytes
                let tmp = try await FileDownloader.download(req) { [weak self] got in
                    Task { @MainActor in self?.items[variant.id]?.received = base + got }
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                completedBytes += (attrs?[.size] as? Int64) ?? 0
                items[variant.id]?.received = completedBytes
            }
            items[variant.id]?.done = true
            let model = LocalModel(id: variant.id, repo: variant.repo, format: variant.format,
                                   displayName: displayName + (variant.format == .gguf ? " · \(variant.label)" : ""),
                                   directory: dir.path, mainFile: variant.mainFile, mmproj: variant.mmproj,
                                   sizeBytes: max(completedBytes, variant.sizeBytes))
            onComplete?(model)
        } catch is CancellationError {
            items[variant.id] = nil
        } catch {
            items[variant.id]?.error = error.localizedDescription
        }
        tasks[variant.id] = nil
    }
}

/// URLSession download with progress callbacks.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: (Int64) -> Void
    private var session: URLSession!

    private init(progress: @escaping (Int64) -> Void) {
        self.progress = progress
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    static func download(_ req: URLRequest, progress: @escaping (Int64) -> Void) async throws -> URL {
        let d = FileDownloader(progress: progress)
        let task = d.session.downloadTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                d.continuation = c
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: APIError(status: http.statusCode, message: "Download failed"))
            continuation = nil
            return
        }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            continuation?.resume(returning: keep)
        } catch { continuation?.resume(throwing: error) }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil; session.invalidateAndCancel() }
    }
}
