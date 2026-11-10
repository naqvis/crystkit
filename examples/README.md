# Examples

Each subdirectory is a complete, runnable example. Work through them in order — each builds on concepts from the previous ones.

## Learning path

| Step | Example                               | What you'll learn                                                                                                                    |
| ---- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 1    | [`hello_world_ipc/`](hello_world_ipc) | Minimum viable app: typed IPC command, JS bridge, event round-trip                                                                   |
| 2    | [`js_menus/`](js_menus)               | Menus created entirely from JS via built-in plugins — no Crystal menu code                                                           |
| 3    | [`note_taking_app/`](note_taking_app) | Built-in plugin (Store), persistent CRUD from the frontend                                                                           |
| 4    | [`file_manager/`](file_manager)       | Two plugins together (FS + Dialog), plugin auto-registration                                                                         |
| 5    | [`system_monitor/`](system_monitor)   | SystemInfo plugin, periodic backend→frontend events                                                                                  |
| 6    | [`nspanel/`](nspanel)                 | **macOS NSPanel examples** — floating panels, tool palettes, overlays, mouse tracking, hover activation, window levels, style masks  |
| 7    | [`showcase/`](showcase)               | Broad feature catalog — every plugin, custom plugins, system tray, global shortcuts, auto-updater, and builder CLI integration       |
| 8    | [`asset_protocol/`](asset_protocol)   | **crystkit:// asset protocol** — serve frontend assets from a virtualfs `.vpak` via a custom URL scheme, no TCP server (Tauri-style) |
| 9    | [`disckpie/`](disckpie)               | Disk usage analyzer — custom Crystal scan commands, IPC progress events, Canvas sunburst chart, drag-to-collect deletion |

## Running an example

```bash
# From the project root
crystal run examples/hello_world_ipc/main.cr
```

All examples use relative paths to the framework source — no `shards` setup needed.

## Showcase — the feature catalog

The [`showcase/`](showcase) example exercises every framework feature:

- A broad built-in plugin set, including FS, Dialog, Clipboard, Notifications, SystemInfo, HTTP, Theme, DPI, Power, Idle, SafeStorage, Taskbar, Kiosk, window effects, DevTools, DragDrop, Hardware, Speech, Positioning, DisplayManager, Toolbar, Printing, Permissions, and more
- Custom plugin (RecentsPlugin) with dependencies
- IPC commands with typed params
- Bidirectional events (backend ↔ frontend)
- System tray with nested menus
- Global keyboard shortcuts
- Auto-updater with download, install, rollback
- Window positioning and screen info
- Native speech synthesis plus speech-recognition language discovery and transcript events
- Localhost static asset server
- Deep link handler
- Single-instance enforcement
- Window state persistence
- Capability manifests and scoped permissions

It also includes a [`crystkit.json`](showcase/crystkit.json) config so you can use it with the builder CLI:

```bash
crystkit build \
  --config examples/showcase/crystkit.json \
  --target dmg \
  --output /tmp/showcase-dist
```

## Standalone low-level examples

These files demonstrate the raw `CrystKit::Webview` primitives directly:

- `typed_bindings_example.cr` — `bind_typed` for compile-time JS bindings
- `multi_window.cr` — raw multi-window lifecycle
- `advanced_features.cr` — RAII windows, lifecycle hooks, async `eval`

These work without any of the App/plugin/capability machinery. Useful when you don't need IPC and just want to drive a webview directly.

## See also

- [Getting started](../guides/getting-started.md) — build the smallest complete app and see it run
