# Synapse

Run AI models on your Mac, or use free cloud models, in one app.

- **Local models**: browse HuggingFace, get recommendations checked against your Mac's memory, and run them with llama.cpp (GGUF) or MLX.
- **Cloud models**: free Google AI Studio, Groq and OpenRouter models, plus Claude and DeepSeek with your own key, or any OpenAI-compatible server. Keys are stored in the macOS Keychain. Synapse checks which models actually work on your key and falls back automatically when one is busy.
- **Capabilities** you can turn on per chat: web search, image generation, computer access (shell, files, AppleScript, screenshots), a browser the model can drive, and websites hosted on localhost.
- **Thinking levels**: Fast, Normal, Think hard, and Think harder (adds a self-review pass).
- **Projects** with shared files and instructions. File changes are shown as a diff (+added / −removed) for approval before anything is written.
- **Presentations**: models can create .pptx slide decks, shown as an attachment you can present.
- **Device control glow**: while a model uses your Mac, the screen edge glows and a Stop button appears.
- **Usage view** with live Groq and Claude limits, request counts for every provider, and a warning when you're running low.
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
