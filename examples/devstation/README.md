# CrystKit DevStation

A **full-featured developer productivity suite** built with CrystKit. This is the framework's flagship demo — it goes far beyond a feature gallery and shows how to build a real, complex native desktop application with a web-native frontend.

## What It Demonstrates

### Frontend

- **Vue 3 + Vite + Pinia + Vue Router** — production-grade SPA, lazy-loaded routes, reactive global stores
- **CodeMirror 6** — a real code editor embedded in the app supporting 10+ languages with syntax highlighting, search, and keybindings
- **Interactive JSON viewer** — recursive tree with expand/collapse for API responses
- **Live sparkline charts** — canvas-drawn, updated at 1 Hz from the event bus

### Backend (Crystal)

- **Custom Crystal modules**: VitalsMonitor, Terminal, HttpClient, Snippets, Notes, FileExplorer
- **Custom plugin (StatsPlugin)**: hooks every IPC invocation, injects JS into every window via `on_window_created`, broadcasts a digest every 10 seconds
- **In-memory store**: non-persistent storage for snippets, notes, HTTP history, and terminal history
- **Live process streaming**: spawn any command, stdout/stderr stream back per-chunk over the event bus
- **Multi-window**: the terminal opens in an independent window

### Framework Features Used

| Feature                              | Where                            |
| ------------------------------------ | -------------------------------- |
| `app.command` (typed)                | All modules                      |
| `app.on` / `app.emit` (event bus)    | Terminal streaming, vitals ticks |
| `ipc.listen` (frontend)              | All views                        |
| `bind_typed` (raw bridge)            | Dashboard ping, Settings test    |
| `Plugin::Base` custom plugin         | `StatsPlugin`                    |
| `on_window_created` JS injection     | `StatsPlugin`                    |
| FS, Dialog, Clipboard, Notifications | Explorer, Settings, Snippets     |
| In-memory store                      | Snippets, Notes, HTTP history, terminal history (non-persistent) |
| Shell, Process                       | Terminal                         |
| HTTP                                 | HTTP Client                      |
| SafeStorage (OS keychain)            | Settings secrets vault           |
| FileWatcher                          | Explorer watch                   |
| Tray + live tooltip                  | main.cr                          |
| GlobalShortcuts                      | main.cr                          |
| MenuBar                              | main.cr                          |
| SingleInstance + DeepLink            | main.cr                          |
| WindowState persistence              | main.cr                          |
| minimize_to_tray                     | main.cr                          |
| Multi-window                         | Settings panel                   |
| DevTools toggle                      | Topbar                           |
| Theme detection + propagation        | App.vue                          |

## Panels

| Panel           | Description                                                                                   |
| --------------- | --------------------------------------------------------------------------------------------- |
| **Dashboard**   | Live CPU/memory charts, system info, IPC stats, native bridge test                            |
| **Terminal**    | Multi-session process spawner with real-time streaming output and command history             |
| **HTTP Client** | Full API client with request collections, variable interpolation, JSON viewer, in-memory history |
| **Snippets**    | Code snippet manager with search, language detection, tags, and pin support                     |
| **Notes**       | Markdown notes with color labels, archive, and search                                          |
| **Explorer**    | File browser with CodeMirror editor, live file watching, search                               |
| **Settings**    | OS keychain vault, global shortcuts, multi-window launcher, DevTools, native bridge test      |

## Running

### Development (hot reload)

```bash
# Terminal 1 — start Vite dev server
cd examples/devstation/frontend
npm install
npm run dev

# Terminal 2 — start Crystal backend pointing at Vite
cd examples/devstation
CRYSTKIT_DEV=true crystal run main.cr
```

### Production build

```bash
cd examples/devstation/frontend
npm install
npm run build

cd ..
crystal run main.cr
```

## Architecture

```
main.cr                    ← app wiring, tray, shortcuts, menus, window
src/
  store.cr                 ← in-memory store (structs + Array/Hash collections)
  vitals_monitor.cr        ← live system metrics → vitals:tick event
  terminal.cr              ← process spawning → terminal:stdout/stderr/exit
  http_client.cr           ← HTTP requests with in-memory history
  snippets.cr              ← search-powered snippet manager
  notes.cr                 ← search-powered notes
  file_explorer.cr         ← FS + FileWatcher + Dialog
  stats_plugin.cr          ← custom Plugin::Base with on_window_created
frontend/
  src/
    ipc.ts                 ← typed IPC bridge
    router.ts              ← Vue Router (hash mode, lazy routes)
    stores/                ← Pinia stores (vitals, terminal, app)
    views/                 ← one Vue SFC per panel
    components/
      CodeEditor.vue       ← CodeMirror 6 wrapper
      JsonViewer.vue       ← interactive JSON tree
      JsonNode.vue         ← recursive node renderer
    styles/main.css        ← full design system (dark + light theme)
```
