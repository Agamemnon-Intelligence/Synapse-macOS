# Synapse

Run AI models on your Mac, or use free cloud models, in one app.

- **Local models**: browse HuggingFace, get recommendations checked against your Mac's memory, and run them with llama.cpp (GGUF) or MLX.
- **Free cloud models**: Google AI Studio, Groq, OpenRouter's free models, or any OpenAI-compatible server. Keys are stored in the macOS Keychain.
- **Capabilities** you can turn on per chat: web search, image generation, computer access (shell, files, AppleScript, screenshots), a browser the model can drive, and websites hosted on localhost.
- **Thinking levels**: Fast, Normal, Think hard, and Think harder (adds a self-review pass).
- **Projects** with shared files and instructions.
- **Usage view** with live Groq limits and request counts for every provider.
- **Terminal**: `synapse chat`, `synapse run <model> "prompt"`, `synapse models`. Synapse also serves every model on `http://127.0.0.1:11435/v1` (OpenAI-compatible).

## Build

Requires macOS 14+ and Xcode. Liquid Glass is used on macOS 26 and later.

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Synapse.xcodeproj -scheme Synapse -configuration Release build
```

Local engines install from **Models → Engines** (`brew install llama.cpp`, and `mlx-lm` in a private Python venv).

## License

MIT © 2026 Miraz Bakis
