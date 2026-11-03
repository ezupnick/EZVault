# EZVault

A light, fast, native SwiftUI iPhone app that chats with **Claude** over your **Obsidian**
vault. Ask questions in natural language and Claude searches, reads, and answers from your
notes — tap through the notes it cites, capture new thoughts, and have Claude write back.

Everything runs on-device except the model call itself: there's no backend to host, and
your notes never leave your phone except as context in the questions you send to Claude.
No external dependencies — only Apple frameworks (SwiftUI, NaturalLanguage, system SQLite).

> The app's display name is **EZVault**; the Xcode project/target is still named `VaultChat`.

## Features

**Chat & retrieval**
- **Chat over your vault** — Claude uses agentic tools (search, read, list, tags, backlinks)
  and answers with the relevant context, streamed token by token. A **Stop** button cancels
  a reply in progress.
- **Hybrid search** — keyword full-text (SQLite FTS5, title-weighted) fused with **on-device
  semantic search** (Apple `NLEmbedding` sentence vectors) via reciprocal-rank fusion, so
  concept and paraphrase queries find the right note even without exact word overlap.
- **Tag & frontmatter aware** — parses YAML frontmatter and extracts frontmatter + inline
  `#tags`; `find_by_tag` lists notes by tag (including nested like `project/ios`).
- **Backlinks** — ask what links to a note, and see a "Linked from" list in the note viewer.
- **Recency & listing** — `list_notes` is newest-first and reports when a list is truncated.

**Reading**
- **Markdown replies** rendered with a lightweight, dependency-free renderer.
- **Tappable links** — cited notes and Obsidian `[[wikilinks]]` are tappable and open the
  exact note in an in-app viewer; wikilinks inside notes navigate note-to-note.

**Capture & write-back**
- **Quick capture** — a toolbar button opens a sheet to jot (or dictate) a thought; it's
  saved as a new timestamped note in a **capture folder** (default `EZVault`, configurable).
- **Voice input** — on-device dictation (Speech + AVAudioEngine) via a mic button in the
  chat bar and the capture sheet.
- **Write-back** — Claude can `append_note`, `create_note`, and `edit_note` (place or revise
  text anywhere via exact-snippet replacement). Non-destructive (no overwrite/delete,
  vault-path validated) and gated by a Settings toggle.

**Navigation & performance**
- **Quick-switcher** — a magnifying-glass toolbar button for instant, local note search and
  open — no API call.
- **Context cap** — only the most recent turns are sent to the API, keeping long chats fast
  and cheap.
- **Auto-reindex on foreground** so notes added since last launch are picked up; offloaded
  iCloud notes are downloaded on demand.

**Setup**
- **iCloud vault, no server** — pick your vault folder once; a security-scoped bookmark keeps
  access across launches.
- **Model toggle** — Claude Opus (best) or Haiku (fastest). API key stored in the Keychain.

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
      VaultStore.swift        Folder bookmark, iCloud sync, indexing, tools, writes, capture
      NoteIndex.swift         SQLite FTS5 + per-note vectors + tags; hybrid/tag/backlink queries
      Embedder.swift          On-device sentence embeddings (NaturalLanguage)
      SpeechRecognizer.swift  On-device dictation (Speech + AVAudioEngine)
      Settings.swift          API key, model, editing toggle, capture folder
      KeychainStore.swift
    ViewModels/ChatViewModel.swift   Streaming, Stop, context cap
    Views/
      ChatView.swift          Chat screen, input bar + mic, toolbar, citation/link routing
      MessageBubble.swift
      MarkdownText.swift      Markdown renderer; linkifies [[wikilinks]]
      NoteViewerView.swift    In-app note viewer with backlinks + note-to-note navigation
      QuickSwitcherView.swift Instant local note search/open
      CaptureView.swift       Quick capture (type or dictate) → capture folder
      SettingsView.swift      API key, vault picker, model, editing toggle, capture folder
```

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
3. Optionally set a **capture folder** (default `EZVault`) and toggle **Allow Claude to edit notes**.

Then: ask a concept question and tap a cited `[[note]]` to open it, use the **🔍** button to
jump to any note, tap **✏️** (or the mic) to capture a thought into your EZVault folder, or
ask Claude to add something to a note.
