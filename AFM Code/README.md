# AFM Code

**On-device AI coding platform for macOS.**

AFM Code is a SwiftUI desktop app that runs large language models locally on your Mac using Apple's [Foundation Models](https://developer.apple.com/documentation/foundationmodels) framework (macOS 27+) and [MLX](https://github.com/ml-explore/mlx-swift) for quantized models. It combines the capabilities of platforms like Pi and Bionic into a single, privacy-first application.

## Key Features

- **On-device AI** — No API keys, no cloud. All inference runs locally on your Mac.
- **Dual model backends**
  - **Apple Foundation Models (AFM)** — Native `FoundationModels` API with tool calling, reasoning, and vision support.
  - **MLX models** — Download and run quantized models from Hugging Face (MLX format) via `mlx-swift-lm-afm`, with full parity: tool calling, reasoning, vision, and speculative decoding.
- **Project-based workspaces** — Assign a folder as a project so the agent can read files, run shell commands, and use Git.
- **Chat sessions** — Multi-turn conversations with context compaction (automatic history summarization when the context window fills).
- **Tool calling** — The agent can read/write files, run shell commands, interact with Git (log, blame, diff, status, branch, show, diff), and search file contents.
- **Approval system** — File writes and shell commands require user approval before execution. Configurable allow, always-allow, and deny.
- **Vision support** — Paste or drag images into the chat input; vision-capable models (GPT-4o, Claude, Qwen3-VL, Gemma 4) can see them.
- **Model picker** — Choose between AFM models and downloaded MLX models per session.
- **Appearance settings** — Chat bubble styles, 15 color palettes, gradient backgrounds per model.
- **VoiceOver support** — Full screen-reader parity with Perspective Intelligence: every message, sidebar row, model card, and status reads cleanly, with turn-lifecycle announcements and user-togglable preferences.
- **Keyboard shortcuts** — The same keystrokes as Perspective Intelligence: stop/regenerate, copy, model picker, composer focus, session navigation, deletion, and recent sessions (see [Keyboard Shortcuts](#keyboard-shortcuts)).

## Architecture

```
AFM Code/
  App/
    AFMCodeApp.swift              # @main entry, state initialization, keyboard commands
    ChatController.swift          # Selection persistence + engine cache
    ChatCommandContext.swift      # Focused values for the keyboard commands
  Features/
    RootView.swift                  # Sidebar + detail pane layout
    Chat/
      ChatView.swift                # Full chat interface with model picker
      ComposerView.swift            # Prompt input with image preview chips
      MessageRowView.swift          # Bubble rendering (user/assistant)
      MessageListView.swift         # Transcript list with scroll behavior
      ModelPickerPanel.swift        # "Choose model" popover
      StepsDisclosureCard.swift     # Collapsible tool steps
      AssistantStatusBadge.swift    # Live status ("Model is thinking…")
      ThinkingCardView.swift        # Chain-of-thought for reasoning models
    Projects/
      ProjectOverviewView.swift     # Project info + missing-folder banner
    Settings/
      SettingsView.swift            # Appearance + model settings
  AI/
    SessionEngine.swift             # Drives one chat session (AFM + MLX)
    Workspace.swift                 # Workspace store, bookmark management
    ToolContext.swift               # Tool runtime (read/write/execute)
    ToolApprovalService.swift       # Approval gate (allow/always-allow/deny)
    ModelCatalog.swift              # AFM model catalog
    MLX/
      MLXModelManager.swift         # MLX model library (download, cache, load)
      MLXFoundationModels/          # MLX adapter layer
      MLXLMCommon/                  # MLX language model abstractions
  Models/
    Project.swift                   # SwiftData: project metadata + bookmark
    ChatSession.swift               # SwiftData: session + messages
    Message.swift                   # SwiftData: individual message
    MlxModel.swift                  # SwiftData: MLX model metadata
    PendingImageAttachment.swift    # Staged image before sending
  Support/
    ChatInputTextView.swift         # Native NSTextView with pasteboard image detection
    ChatBubbleStyle.swift           # Bubble style / model colors
    ChatBackgroundStyle.swift       # 15 palettes + window background
    ModelGradientBackground.swift   # Per-model gradient
    ModelIdentity.swift             # 12 model gradient identities
    PlatformSupport.swift           # Cross-platform helpers
    MarkdownBlock.swift             # Markdown parser
    StreamingMarkdownDocument.swift # Streaming markdown renderer
    ChatWindowBackground.swift      # Window background style
    ProjectPicker.swift             # NSOpenPanel for project selection
```

## Getting Started

### Requirements

- macOS 27.0+ (Sequoia with Foundation Models SDK)
- Apple Silicon Mac (M1 or later) for MLX models

### Building

```bash
cd "AFM Code"
xcodebuild -project "AFM Code.xcodeproj" -scheme "AFM Code" -configuration Debug build
```

### First Launch

1. Open the app. You'll see a sidebar with no projects.
2. Click **Add Project** (or the `+` button) to select a folder on your Mac.
3. The app will create a security-scoped bookmark to that folder.
4. Start a new chat session. The model catalog will probe for available AFM models.
5. Download an MLX model from Hugging Face via the **Models** tab in Settings.
6. Select a model from the session's model badge (bottom-left of the composer).

## Model Backends

### Apple Foundation Models (AFM)

Uses the native `FoundationModels` framework. Supports:
- Chat (text, reasoning, vision)
- Tool calling (read, write, shell, Git, search)
- Context compaction (automatic summarization)

Models are probed automatically at launch and listed in the model picker.

### MLX Models

Uses the `mlx-swift-lm-afm` library (vendored fork). Supports:
- Download from Hugging Face (MLX-converted repos)
- Quantized models (4-bit, etc.)
- Full feature parity with AFM: tool calling, reasoning, vision, speculative decoding
- Metal GPU acceleration on Apple Silicon

Browse and download models in **Settings → Models**.

## Keyboard Shortcuts

The same keystrokes Perspective Intelligence provides, adapted to AFM Code's single-window sessions model. All live in the **Sessions** menu and File menu.

| Shortcut | Action |
|----------|--------|
| ⌘N | New Session (requires a selected project) |
| ⌘. | Stop Response (enabled while a turn is in flight) |
| ⌘R | Regenerate Response (drops the last exchange and re-sends the prompt) |
| ⇧⌘C | Copy Last Response to the pasteboard |
| ⌥⇧⌘C | Copy the full conversation to the pasteboard |
| ⇧⌘M | Choose Model… |
| ⌘L | Focus the message box |
| ⌥⌘↑ / ⌥⌘↓ | Previous / Next Session |
| ⌘⌫ | Delete Session… (skipped while the text view is focused, so ⌘⌫ keeps its default "delete to beginning of line") |
| ⌘1–⌘9, ⌘0 | Jump to the 1–10 most recent sessions |

## Phases

| Phase | Description |
|-------|-------------|
| 0 | Project setup, renaming, bundle configuration |
| 1 | Core chat system, SessionEngine, SwiftData models |
| 2 | Tool runtime (read/write/execute), approval system |
| 3 | Project assignment, tool context, Git integration |
| 4 | Context compaction (automatic summarization) |
| 5 | MLX model support (download, cache, load) |
| 6 | MLXFoundationModels adapter (tool calling, reasoning, vision parity) |
| 7 | MLX language model support (mlx-swift-lm-afm) |
| 8 | Chat UI from Perspective Intelligence (bubbles, input, model picker) |
| 8b | Project picker folder creation (`canCreateDirectories = true`) |
| 9 | Vision/attachment support (paste/drag images, preview chips, message bubbles) |
| 10 | VoiceOver parity with Perspective Intelligence (message labels, turn announcements, settings) |
| 11 | Keyboard shortcuts from Perspective Intelligence (Sessions menu: stop, regenerate, copy, model picker, navigation, deletion, recents) |

## Privacy

- All inference runs on-device. No data leaves your Mac.
- Projects are accessed via security-scoped bookmarks (sandbox-compatible).
- No telemetry, no analytics, no cloud services.

## License

Private project. All rights reserved.
