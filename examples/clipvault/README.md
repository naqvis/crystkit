# ClipVault — Clipboard History Manager

A local-first clipboard history manager built with CrystKit. Inspired by the clipboard utilities in the [awesome-tauri](https://github.com/tauri-apps/awesome-tauri) ecosystem.

## Features

- **Clipboard monitoring** — automatically captures text copied to clipboard
- **Search history** — filter through past clips instantly
- **Favorites** — pin important items with one click
- **Delete & clear** — remove individual items or wipe all history
- **System tray** — quick access from the menu bar
- **Global shortcut** — `Meta+Shift+V` to focus the window from anywhere
- **Persistent storage** — SQLite-backed, survives restarts

## Run

```bash
crystal run examples/clipvault/main.cr
```

## Usage

1. Copy any text — ClipVault captures it automatically
2. Open ClipVault (global shortcut `Cmd+Shift+V`)
3. Click any item to copy it back to the clipboard
4. Use the search bar to filter history
5. Star items to favorite them, or delete unwanted ones

## Architecture

| Layer    | Technology                         |
| -------- | ---------------------------------- |
| Backend  | Crystal + CrystKit                 |
| Storage  | SQLite via `Features::Database`    |
| Clipboard| `Features::Clipboard` (monitoring) |
| Frontend | HTML/CSS/JS (inline webview)       |
| Tray     | `Features::SystemTray`             |
| Shortcuts| `Features::GlobalShortcuts`        |

## Key Patterns Demonstrated

- **Plugin composition**: `Plugins::Clipboard`, `Plugins::Dialog`, `Plugins::Notifications`
- **Feature modules**: `Features::Clipboard` (monitor), `Features::Database`, `Features::SystemTray`, `Features::GlobalShortcuts`, `Features::MenuBar`
- **Background fiber**: clipboard monitoring runs in a `spawn` block
- **Real-time IPC**: backend emits `clipboard:new` events to the frontend on clipboard change
- **Custom IPC commands**: `clipvault:history`, `clipvault:favorite`, `clipvault:delete`, `clipvault:clear`, `clipvault:status`

## Inspired by

Apps from [awesome-tauri](https://github.com/tauri-apps/awesome-tauri) including clipboard utilities, Dropcode (snippet manager), and the broader productivity tool ecosystem.
