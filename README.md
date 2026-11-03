# EZVault

A light, fast, native SwiftUI iPhone app that chats with **Claude** over your **Obsidian**
vault. Ask questions in natural language and Claude searches, reads, and answers from your
notes — and can capture new thoughts back into the vault.

Everything runs on-device except the model call itself: there's no backend to host, and
your notes never leave your phone except as context in the questions you send to Claude.

> The app's display name is **EZVault**; the Xcode project/target is still named `VaultChat`.

## Features

- **Chat over your vault.** Claude uses agentic tools to search, read, and list your notes,
  then answers with the relevant context — streamed token by token.
- **Hybrid search.** Keyword full-text (SQLite FTS5, title-weighted) fused with **on-device
  semantic search** (Apple `NLEmbedding` sentence vectors) via reciprocal-rank fusion, so
  concept and paraphrase queries find the right note even without exact word overlap.
- **Markdown replies with tappable citations.** Answers render as Markdown; cited notes are
  tappable links that open the note in an in-app viewer.
- **Write-back / capture.** Claude can `append_note`, `create_note`, and `edit_note` (place
  or revise text anywhere via exact-snippet replacement) — e.g. "add this to today's daily."
  Non-destructive (no overwrite/delete, vault-path validated) and gated by a Settings toggle.
- **iCloud vault, no setup server.** Pick your vault folder once; a security-scoped bookmark
  keeps access across launches. The index auto-refreshes when the app returns to the
  foreground, and offloaded iCloud notes are downloaded on demand.
- **Model toggle.** Claude Opus (best) or Haiku (fastest). API key stored in the Keychain.

## Layout

```
VaultChat/
  VaultChat.xcodeproj         Hand-written Xcode project (no generator needed)
  project.yml                 Legacy XcodeGen spec — reference only, not used by the build
  Sources/
    VaultChatApp.swift        App entry; re-indexes on foreground
    Models/ChatMessage.swift
    Services/
      AnthropicClient.swift   Streaming Messages API client (plain chat fallback)
      VaultAgent.swift        Agentic tool loop + tool/system definitions
      VaultStore.swift        Folder bookmark, iCloud sync, indexing, tool execution, writes
      NoteIndex.swift         SQLite FTS5 + per-note vectors; hybrid search
      Embedder.swift          On-device sentence embeddings (NaturalLanguage)
      Settings.swift          API key, model, note-editing toggle
      KeychainStore.swift
    ViewModels/ChatViewModel.swift
    Views/
      ChatView.swift          Chat screen, input bar, tool-activity row, citation routing
      MessageBubble.swift
      MarkdownText.swift       Lightweight Markdown renderer (no dependencies)
      NoteViewerView.swift     In-app note viewer (opened from a citation)
      SettingsView.swift       API key, vault picker, model, editing toggle
```

No external dependencies — only Apple frameworks (SwiftUI, NaturalLanguage, system SQLite).

## Build & run

Requires **Xcode** (full install, not just Command Line Tools). Open and run:

```bash
open VaultChat.xcodeproj   # then select a simulator or your device and press ⌘R
```

Or from the command line, for a simulator:

```bash
xcodebuild -project VaultChat.xcodeproj -scheme VaultChat \
  -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

## Running on your iPhone

1. Open `VaultChat.xcodeproj`, select the **VaultChat** target → **Signing & Capabilities**,
   check *Automatically manage signing*, and choose your Apple ID team (a free one works).
2. Plug in your iPhone (unlocked), select it as the run destination, press **⌘R**.
3. On the phone: **Settings → General → VPN & Device Management** → trust the developer app.

> A free Apple ID signs apps for ~7 days; re-run from Xcode to refresh.

## Configuration & use

On first launch EZVault opens Settings:

1. Paste your **Anthropic API key** (kept in the iOS Keychain, sent only to `api.anthropic.com`).
2. **Choose Vault Folder** — point it at your Obsidian vault in **iCloud Drive**. The first
   index reads and embeds every note (a few minutes for a large vault); after that it's
   incremental.
3. Optionally toggle **Allow Claude to edit notes**.

Then ask away — try a concept search, tap a cited note to open it, or ask Claude to add
something to today's daily note.
