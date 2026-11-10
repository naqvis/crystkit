# Showcase

A flagship reference application demonstrating every feature the Crystal Webview framework offers. Read top-to-bottom alongside `main.cr` to see how the pieces fit together in a realistic app.

## Run

```bash
crystal run examples/showcase/main.cr
```

A 1100×750 window opens with a tabbed UI. Try every tab to exercise the underlying feature.

## What it demonstrates

Every framework capability surfaces somewhere in the UI. This table maps each tab to the framework concept it proves out.

| UI tab             | Framework feature(s)                                                                                                                                         |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Overview**       | App startup, periodic backend events (`clock:tick`, `stats:tick`), `Plugins::Notifications`, `Plugins::External`, `Plugins::SystemInfo`, capability log path |
| **Files**          | `Plugins::FS` commands (`fs.list_dir`, `fs.read_text`, `fs.write_text`), bridging FS → custom `RecentsPlugin` via events                                     |
| **Clipboard**      | `Plugins::Clipboard` (`clipboard:read_text`, `clipboard:write_text`); `clipboard:version` shows OS change counter, polls for external changes                |
| **Dialogs**        | `Plugins::Dialog` (`dialog:open_file`, `dialog:save_file`, `dialog:select_folder`)                                                                           |
| **HTTP**           | `Plugins::HTTP` + a long-running `sync:bulk_fetch` that streams progress events; `tls:info` shows TLS server cert status                                     |
| **WebSocket**      | `CrystKit::Features::WebSocketClient` with auto-reconnect, custom `ws.*` commands, bidirectional events                                                       |
| **Processes**      | `CrystKit::Features::ProcessManager`: spawn, stream stdout, kill                                                                                              |
| **Shell**          | `CrystKit::Features::ShellExecutor`: argument sanitization, timeout                                                                                           |
| **System**         | `Plugins::SystemInfo` for OS, CPU, memory, hostname, home dir                                                                                                |
| **Tray**           | `SystemTray` with nested submenu (Window → Tile Left/Right/Reset), tooltip, click events                                                                     |
| **Shortcuts**      | `GlobalShortcuts`: register/unregister system-wide hotkeys                                                                                                   |
| **Autostart**      | `Autostart`: enable/disable login-time launch                                                                                                                |
| **Screen**         | `WindowPositioner`: display list, cursor position, screen-change detection                                                                                   |
| **Speech**         | `Plugins::Speech`: native voice discovery and synthesis plus recognition-language selection, permissions, and transcript events                             |
| **Updates**        | `AutoUpdater`: check, download, install, and rollback updates against a local manifest                                                                       |
| **Window**         | `EnhancedWindow`: always-on-top, opacity, frameless — opens a dedicated demo window on first action                                                          |
| **Recents**        | Custom plugin (`RecentsPlugin`) with dependencies, persistence via `Plugins::Store`, IPC commands, event subscription                                        |
| **Device**         | `SystemTheme` (light/dark detection), `DPIMonitor` (scale factor + display info), `PowerMonitor` (battery/AC status), `IdleMonitor` (user idle seconds)      |
| **Storage**        | `SafeStorage`: store, retrieve, delete, and list credentials in the OS keychain (macOS Keychain, Windows Credential Manager, Linux libsecret)                |
| **Watcher**        | `FileWatcher`: watch directories for file system changes with OS-native events (inotify on Linux, polling on macOS/Windows); background fiber channel events |

## Cross-cutting features (no UI tab — wired in `main.cr`)

- **Capability manifest** — `capabilities.json` carries app-owned grants, resource scopes, and optional per-window restrictions. Plugin capabilities are granted from plugin metadata when each plugin is registered.
- **Single-instance enforcement** — `CrystKit::Features::SingleInstance`. A second launch forwards its argv to the running copy and exits.
- **Deep links** — registers the `showcase://` URL scheme via `CrystKit::Features::DeepLink`. Activating the scheme emits a backend event the frontend can react to.
- **File-backed logging** — `CrystKit::Features::AppLogger` with size-based rotation, writing to `<storage>/showcase.log`.
- **Asset protocol** — the `assets/` directory is served to the window via CrystKit's `crystkit://` asset protocol (wired from `AppConfig#frontend_dist`). The former localhost HTTP asset server now lives in the optional `crystkit-http-server` shard.
- **Window state persistence** — `CrystKit::Features::WindowState` remembers size across runs.
- **close-to-hide** — the close button hides to tray instead of quitting (via `webview.minimize_to_tray = true`).
- **Taskbar progress** — `TaskbarProgress` sets progress, badge, overlay icon, and progress state on the OS taskbar/dock icon.
- **Kiosk mode** — `KioskMode` toggles fullscreen undecorated mode via `enter` / `exit` with active-state query.
- **Auto-injected JS bridge** — `window.__CRYSTKIT_IPC__` is available on every page from the first script, no setup required.

## Project layout

```
showcase/
  main.cr                       # entry point: wires everything
  capabilities.json             # capability manifest
  src/
    background.cr               # periodic event streams
    custom_plugin.cr            # RecentsPlugin demonstrating the protocol
    commands/
      sync.cr                   # HTTP wrapper commands
      shell_box.cr              # ShellExecutor sandbox
      process_box.cr            # ProcessManager sandbox
      websocket_chat.cr         # WebSocketClient sandbox
  assets/
    index.html                  # multi-tab UI
    app.js                      # frontend logic (vanilla, ~250 LOC)
    styles.css                  # light/dark theme
```

## Reading order

1. **`main.cr`** top-to-bottom. The 13 numbered sections each demonstrate a different concern.
2. **`src/custom_plugin.cr`** — full plugin protocol example.
3. **`assets/app.js`** — how a frontend talks to all of this through `window.__CRYSTKIT_IPC__`.

## What's where in the codebase

| If you want to see how...                 | Look at                                        |
| ----------------------------------------- | ---------------------------------------------- |
| Parameters get decoded into Crystal types | `CrystKit::App#command` in `src/core/app.cr`    |
| The IPC bridge gets injected              | `setup_ipc_client` in `src/ipc/js_bridge.cr`   |
| Capabilities are checked                  | `src/security/capability.cr`                   |
| Plugin lifecycle works                    | `src/plugins/base.cr` and `CrystKit::App#plugin` |
| The IPC router dispatches commands        | `src/ipc/router.cr`                            |
| Static assets are served                 | `CrystKit::App` + `AppConfig#frontend_dist` (asset protocol); localhost HTTP serving lives in the `crystkit-http-server` shard |

## Customizing

Try these as exercises:

1. Add a new tab that uses `Plugins::Clipboard.read_html` / `write_html` (already exposed by the plugin).
2. Add a `recents:open` command to the custom plugin that triggers `external:open_file` for the chosen path.
3. Replace the inline HTML/JS with any frontend framework (Vue, React, Svelte, etc.) using a dev server — point the window URL at it.
4. Add a new plugin (e.g. `TelemetryPlugin`) following the protocol in `src/custom_plugin.cr`.

## Capability manifest tour

`capabilities.json`:

```json
{
  "capabilities": [...],          // app-owned grants
  "groups": {                     // named bundles for human readability
    "editor": ["fs:read", "fs:write", "dialog:open", "dialog:save"]
  },
  "windows": {                    // per-window restrictions
    "settings": ["clipboard:read", "clipboard:write"]
  },
  "scopes": {                     // resource access patterns
    "fs": ["~/Documents", "/tmp/crystkit-showcase/*"],
    "http": ["https://api.example.com/*"]
  }
}
```

A future iteration of this app will add a "Settings" sub-window that only has the `windows.settings` capabilities — try it as an exercise to see how `app.capabilities.grant_to_window` works in practice.

## Why this is the recommended stack

The showcase uses **plain HTML + vanilla JS** served over CrystKit's `crystkit://` asset protocol. This is the closest analog to what most production Tauri-style apps end up doing during development:

- No frontend build pipeline to debug
- Hot reload happens by re-launching Crystal (or with `crystal run` + `entr`)
- The `__CRYSTKIT_IPC__` bridge is identical regardless of frontend framework — swap in any toolchain when the app outgrows vanilla, but keep the same Crystal backend

## See also

- [`docs/README.md`](../../docs/README.md) — framework overview
- [`docs/plugins.md`](../../docs/plugins.md) — built-in plugin reference
- [`docs/recipes.md`](../../docs/recipes.md) — packaging, signing, frontend integration patterns
