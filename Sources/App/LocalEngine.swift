import Foundation
import Observation

/// Runs local models by managing a `llama-server` (llama.cpp) or `mlx_lm.server` process,
/// both of which expose an OpenAI-compatible API on 127.0.0.1.
@MainActor
@Observable
final class LocalEngine {
    nonisolated static let port = 18080

    enum Status: Equatable {
        case stopped
        case loading(String)
        case running(String)
        case failed(String)
    }

    var status: Status = .stopped
    var loadedModelID: String?
    var log = ""
    var installing = false
    var installLog = ""

    private var process: Process?

    // MARK: Engine discovery

    var llamaServerPath: String? {
        ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server",
         NSHomeDirectory() + "/.local/bin/llama-server"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var mlxPython: String? {
        let py = Paths.mlxVenv.appendingPathComponent("bin/python").path
        let marker = Paths.mlxVenv.appendingPathComponent("lib")
        guard FileManager.default.isExecutableFile(atPath: py),
              let libs = try? FileManager.default.contentsOfDirectory(atPath: marker.path),
              libs.contains(where: { FileManager.default.fileExists(atPath: marker.appendingPathComponent("\($0)/site-packages/mlx_lm").path) })
        else { return nil }
        return py
    }

    var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func isAvailable(_ format: LocalModel.Format) -> Bool {
        format == .gguf ? llamaServerPath != nil : (mlxPython != nil && HardwareInfo.current.isAppleSilicon)
    }

    // MARK: Install

    func installLlama() async {
        guard let brew = brewPath else {
            installLog = "Homebrew isn't installed. Install it from https://brew.sh, then try again."
            return
        }
        installing = true
        installLog = "$ brew install llama.cpp\n"
        let out = await Task.detached { runProcess(brew, ["install", "llama.cpp"], timeout: 1800) }.value
        installLog += out.output
        installLog += out.status == 0 ? "\n✓ llama.cpp installed." : "\n✗ Install failed (exit \(out.status))."
        installing = false
    }

    func installMLX() async {
        installing = true
        installLog = ""
        // mlx-lm needs a Python that MLX ships wheels for.
        let candidates = ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.13", "/usr/local/bin/python3.12",
                          "/opt/homebrew/opt/python@3.12/bin/python3.12", "/opt/homebrew/opt/python@3.13/bin/python3.13"]
        var python = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if python == nil, let brew = brewPath {
            installLog += "$ brew install python@3.12\n"
            let r = await Task.detached { runProcess(brew, ["install", "python@3.12"], timeout: 1800) }.value
            installLog += r.output + "\n"
            python = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        guard let python else {
            installLog += "✗ Couldn't find Python 3.12 or 3.13. Install Homebrew (https://brew.sh) and try again."
            installing = false
            return
        }
        let venv = Paths.mlxVenv.path
        installLog += "$ \(python) -m venv \(venv)\n"
        let r1 = await Task.detached { runProcess(python, ["-m", "venv", venv], timeout: 300) }.value
        installLog += r1.output
        installLog += "$ pip install -U mlx-lm\n"
        let pip = venv + "/bin/pip"
        let r2 = await Task.detached { runProcess(pip, ["install", "-U", "mlx-lm"], timeout: 1800) }.value
        installLog += r2.output
        installLog += r2.status == 0 ? "\n✓ MLX installed." : "\n✗ Install failed (exit \(r2.status))."
        installing = false
    }

    // MARK: Load / stop

    func ensureLoaded(_ model: LocalModel, contextSize: Int) async throws {
        if loadedModelID == model.id, case .running = status, process?.isRunning == true { return }
        stop()
        status = .loading(model.displayName)
        log = ""

        let p = Process()
        switch model.format {
        case .gguf:
            guard let bin = llamaServerPath else {
                status = .failed("llama.cpp isn't installed")
                throw APIError(status: 0, message: "llama.cpp isn't installed. Open Models → Engines and click Install.")
            }
            guard let main = model.mainFile else { throw APIError(status: 0, message: "Model file missing") }
            p.executableURL = URL(fileURLWithPath: bin)
            var args = ["-m", model.directory + "/" + main, "--host", "127.0.0.1", "--port", String(Self.port),
                        "-c", String(contextSize), "--jinja", "-ngl", "999", "--alias", model.displayName]
            if let mm = model.mmproj { args += ["--mmproj", model.directory + "/" + mm] }
            p.arguments = args
        case .mlx:
            guard let py = mlxPython else {
                status = .failed("MLX isn't installed")
                throw APIError(status: 0, message: "MLX isn't installed. Open Models → Engines and click Install.")
            }
            p.executableURL = URL(fileURLWithPath: py)
            p.arguments = ["-m", "mlx_lm.server", "--model", model.directory, "--host", "127.0.0.1", "--port", String(Self.port)]
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard !s.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.log += s
                if self.log.count > 40_000 { self.log = String(self.log.suffix(30_000)) }
            }
        }
        try p.run()
        process = p
        loadedModelID = model.id

        // Wait until the server answers.
        let healthPath = model.format == .gguf ? "/health" : "/v1/models"
        let url = URL(string: "http://127.0.0.1:\(Self.port)\(healthPath)")!
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if !p.isRunning {
                status = .failed("The engine exited")
                loadedModelID = nil
                throw APIError(status: 0, message: "The local engine stopped while loading.\n" + String(log.suffix(1500)))
            }
            if let (_, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                status = .running(model.displayName)
                return
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        stop()
        throw APIError(status: 0, message: "Timed out loading the model.")
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        loadedModelID = nil
        status = .stopped
    }

    /// The `model` value to send to the running server.
    func requestModelName(for model: LocalModel) -> String {
        model.format == .mlx ? model.directory : model.displayName
    }
}
