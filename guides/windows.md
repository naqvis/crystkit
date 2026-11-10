# Windows

CrystKit windows are runtime-owned native WebView windows. You create them through `CrystKit::App`, the runtime registers them, wires IPC into them, associates them with security context, and destroys them during shutdown.

Read [Architecture](architecture.md) first if runtime ownership is not clear yet.

## Create A Window

The simplest window loads HTML:

```crystal
window = app.window(
  title: "Notes",
  width: 1024,
  height: 720,
  html: File.read("frontend/index.html"),
)
```

Or navigate to a URL:

```crystal
window = app.window(
  title: "Notes",
  url: "http://localhost:5173",
  debug: true,
)
```

`html` and `url` are mutually exclusive. Use `html` for static or bundled assets. Use `url` during development when a frontend dev server is running.

## What `app.window` Does

Creating a window is more than allocating a WebView:

1. The platform backend creates the native window.
2. The window is registered in `Core::WindowRegistry`.
3. CrystKit injects the JavaScript IPC bridge.
4. The window receives a runtime identity.
5. Security checks can use that identity for per-window authority.
6. Plugins are notified through `on_window_created`.
7. Runtime shutdown can clean the window up.

That is why windows should be created through `App`, not through platform backends directly.

## Labels

Labels make windows addressable:

```crystal
main = app.window(title: "Notes", label: "main")
settings = app.window(title: "Settings", label: "settings", visible: false)
```

Use labels when:

- you need to find a window later,
- frontend IPC authority differs by window,
- events target a specific window,
- parent-child relationships matter,
- a plugin needs to recognize a window.

Lookup:

```crystal
settings = app.window_registry.find("settings")
settings.try(&.show)
```

Targeted event:

```crystal
app.emit("settings:opened", {"source" => "menu"}, target: app.window_registry.find?("settings"))
```

## Window Options

Keyword arguments cover the common case:

```crystal
app.window(
  title: "Preview",
  width: 640,
  height: 480,
  label: "preview",
  visible: true,
  debug: false,
  html: preview_html,
)
```

Use `WindowOptions` when you need the full surface:

```crystal
options = CrystKit::Core::WindowOptions.new(
  title: "Settings",
  width: 480,
  height: 360,
  label: "settings",
  visible: false,
  frameless: true,
  transparent: true,
  opacity: 0.95,
  always_on_top: true,
  minimize_to_tray: true,
  fullscreen: false,
  x: 100,
  y: 200,
)

settings = app.window(options)
```

For inline configuration, use the block API:

```crystal
app.window(title: "TrayApp", label: "main", html: app_html) do |w|
  w.minimize_to_tray = true
  w.always_on_top = true
  w.frameless = true
end
```

The block API works with both `WindowOptions` and keyword arguments, and the window is still returned for chaining or later use.

Common options:

| Option | Type | Default | Purpose |
|--------|------|---------|---------|
| `title` | `String` | `"Window"` | Native title bar text. |
| `width`, `height` | `Int32` | `800`, `600` | Initial size. |
| `label` | `String?` | `nil` | Runtime identifier for lookup, targeting, and security. |
| `visible` | `Bool` | `true` | Whether to show immediately. |
| `url` | `String?` | `nil` | Page URL to load. |
| `html` | `String?` | `nil` | Inline or file-loaded HTML. |
| `debug` | `Bool` | `false` | Enable debugging/devtools support when available. |
| `frameless` | `Bool` | `false` | Remove standard window decorations. |
| `transparent` | `Bool` | `false` | Allow transparent content when supported. |
| `opacity` | `Float64` | `1.0` | Window opacity (0.0–1.0). |
| `always_on_top` | `Bool` | `false` | Keep the window above normal windows. |
| `modal` | `Bool` | `false` | Model the window as modal when supported. |
| `minimize_to_tray` | `Bool` | `false` | Close button hides to tray instead of quitting. |
| `fullscreen` | `Bool` | `false` | Start in fullscreen mode. |
| `x`, `y` | `Int32?` | `nil` | Initial screen position. |
| `preload_scripts` | `Array(String)` | `[]` | JS to inject before page load. |
| `csp` | `String?` | `nil` | Per-window Content-Security-Policy. |

Platform support for advanced options varies. Use [Cross-platform](cross-platform.md) when relying on a specific native behavior.

## Window Operations

`Core::Window` exposes common operations:

```crystal
window.show
window.hide
window.focus
window.minimize
window.maximize
window.restore
window.fullscreen = true
window.navigate("https://example.com")
window.eval("console.log('from Crystal')")
window.move(100, 100)
window.size(900, 600)
window.destroy
```

Use these operations from application commands, menus, plugins, or lifecycle hooks when the backend owns the decision.

## Window-Owned Features

Window-level native features attach through `Core::Window` instead of raw native handles:

```crystal
window.effects do |effects|
  effects.config.mica = true
end

window.devtools = CrystKit::Features::DevTools.new(
  CrystKit::Features::DevToolsConfig.new(enabled: true)
)
window.open_devtools

window.window_state = CrystKit::Features::WindowState.new(
  "main",
  storage_dir: app.config.storage_dir,
)
window.save_window_state
```

Use low-level APIs that accept `Void*` or `native_handle(...)` only for backend integration and platform-specific interop.

If the frontend needs to request a window action, expose a command:

```crystal
app.command "settings.show" do
  app.window_registry.find("settings").try(&.show)
  true
end
```

```js
await ipc.invoke("settings.show");
```

## Lifecycle Events

Windows can emit lifecycle events:

```crystal
window.on("focus") { |_| puts "focused" }
window.on("blur") { |_| puts "blurred" }
window.on("resize") { |w| puts "#{w.width}x#{w.height}" }
window.on("move") { |_| puts "moved" }
window.on("show") { |_| puts "shown" }
window.on("hide") { |_| puts "hidden" }
window.on("destroy") { |_| puts "destroyed" }
```

Use lifecycle events for behavior local to the window. Use app lifecycle hooks for application-wide startup or shutdown work.

## Multi-Window Design

Create multiple windows when they have different jobs:

```crystal
main = app.window(
  title: "Notes",
  label: "main",
  html: File.read("frontend/index.html"),
)

preview = app.window(
  title: "Preview",
  label: "preview",
  visible: false,
  html: File.read("frontend/preview.html"),
)

settings = app.window(
  title: "Settings",
  label: "settings",
  visible: false,
  html: File.read("frontend/settings.html"),
)
```

Common patterns:

| Pattern | Use |
| --- | --- |
| Main + settings | Keep configuration separate from the primary workflow. |
| Main + preview | Show read-only or derived content with narrower authority. |
| Main + helper | Run a specialized tool without crowding the main UI. |
| Hidden tray window | Keep app services alive while UI is hidden. |

Avoid creating multiple windows only because a web app would have multiple routes. A single window can still use frontend routing.

## Parent-Child Relationships

Some windows are naturally related. A settings or preview window may belong to a main window. Parent-child relationships affect modality, ownership, and capability inheritance. Modal windows require the `WindowOptions` + `parent_label:` overload — the keyword-argument `app.window(...)` form does not accept `modal` or `parent_label`.

```crystal
main = app.window(title: "Notes", label: "main")

preview_options = CrystKit::Core::WindowOptions.new(
  title: "Preview",
  label: "preview",
  modal: true,
)

preview = app.window(preview_options, parent_label: "main")
```

When security inheritance is enabled, the child can inherit capabilities through the parent chain.

## Windows And Security

Per-window authority depends on labels:

```json
{
  "windows": {
    "main": ["fs:read", "fs:write", "dialog:open"],
    "preview": ["fs:read"],
    "settings": []
  }
}
```

Then create windows with matching labels:

```crystal
app.window(title: "Notes", label: "main")
app.window(title: "Preview", label: "preview")
app.window(title: "Settings", label: "settings")
```

When the preview frontend invokes a privileged command, CrystKit can deny `fs:write` even if the main window is allowed to write. This is the main reason labels should be stable in production apps.

Runtime grants are also available:

```crystal
app.capabilities.grant_to_window("clipboard:read", "main")
app.capabilities.grant_temporary_to_window("dialog:open", "settings", 1.minute)
app.capabilities.set_window_parent("preview", "main")
```

## Plugins And Window Creation

Plugins can react when windows are created:

Override this in a `CrystKit::Plugin::Base` subclass; CrystKit invokes it from `App#wire_window` for every newly created window.

```crystal
def on_window_created(window : CrystKit::Core::Window) : Nil
  return unless window.label == "main"

  # Attach plugin behavior for the main window.
end
```

Use this for plugin behavior that depends on the presence of a specific window, such as menus, toolbar integration, tray behavior, drag regions, or window state.

## Development Versus Production Content

During development, a window often loads a frontend dev server:

```crystal
app.window(
  title: "Notes",
  url: "http://localhost:5173",
  debug: true,
)
```

In production, it usually loads built assets:

```crystal
app.window(
  title: "Notes",
  html: File.read("frontend/dist/index.html"),
)
```

The builder can start and wait for the dev server, but the runtime window still loads the URL or HTML you provide.

## Shutdown

When the app shuts down, CrystKit destroys registered windows. Put application-wide cleanup in app lifecycle hooks or plugin cleanup methods:

```crystal
app.on_shutdown do
  puts "Application is shutting down"
end
```

Use window `destroy` events for cleanup local to that window.

## Next

Run `crystkit --help` and the relevant subcommand’s `--help` if you need to connect development URLs, frontend builds, and bundled assets.

Read [Security](security.md) if different windows need different authority.

Read [Plugins](plugins.md) if native features need to react to window creation or expose window-related commands to the frontend.
