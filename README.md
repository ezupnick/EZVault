# VaultChat

A light, native SwiftUI iPhone app that chats with Claude over your Obsidian vault.

**Phase 1:** streaming chat with Claude + API-key settings.
**Phase 2:** pick your iCloud vault folder, build a local SQLite/FTS5 index, and give
Claude `search_notes` / `read_note` / `list_notes` tools so it answers from your notes.

Both phases are written. Nothing has been compiled yet — that happens once Xcode is
installed (see Prerequisites). Expect to fix a few compile errors on the first build;
the vault layer in particular hasn't run.

## Layout

```
VaultChat/
  project.yml                 XcodeGen spec (generates VaultChat.xcodeproj)
  Sources/
    VaultChatApp.swift        App entry
    Models/ChatMessage.swift
    Services/
      AnthropicClient.swift   Streaming Messages API client (plain chat)
      VaultAgent.swift        Agentic tool loop (search/read/list notes) over the vault
      VaultStore.swift        Folder bookmark, iCloud sync, indexing, tool execution
      NoteIndex.swift         SQLite FTS5 full-text index (no external deps)
      Settings.swift          Model choice + API key (Keychain-backed)
      KeychainStore.swift
    ViewModels/ChatViewModel.swift
    Views/
      ChatView.swift          Chat screen + input bar + tool-activity row
      MessageBubble.swift
      SettingsView.swift      API key, vault folder picker, model picker
```

## Prerequisites (one-time)

This Mac currently has only the Command Line Tools. Building/running an iOS app needs **full Xcode**:

1. Install **Xcode** from the Mac App Store (large download).
2. Point the toolchain at it and accept the license:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

## Build & run in the Simulator

The project file is generated from `project.yml` with [XcodeGen]:

```bash
cd "VaultChat"
xcodegen generate         # writes VaultChat.xcodeproj
open VaultChat.xcodeproj   # then press ⌘R, or use the build steps below
```

Once Xcode is installed, I (Claude Code) can generate the project, build it, and drive the
iOS Simulator from here to show it running and iterate on it.

## Running on your actual iPhone

1. Open `VaultChat.xcodeproj` in Xcode.
2. Select the **VaultChat** target → Signing & Capabilities → check *Automatically manage
   signing* and pick your Apple ID as the team (a free Apple ID works for personal use).
3. Plug in your iPhone, select it as the run destination, press ⌘R.
4. On the phone: Settings → General → VPN & Device Management → trust the developer app.

## Configuration

On first launch the app opens Settings and asks for your Anthropic API key. It's stored in
the iOS Keychain on-device and sent only to `api.anthropic.com`.

[XcodeGen]: https://github.com/yonaskolb/XcodeGen
