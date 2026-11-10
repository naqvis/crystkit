# Plugins

Plugins are how CrystKit exposes native desktop features and reusable application extensions. A plugin can register IPC commands, declare what capabilities those commands require, receive configuration, react to window creation, and clean up during shutdown.

Read [Security](security.md) first if capabilities and frontend command authority are not clear yet.

## Why Plugins Exist

Desktop features are not just helper functions. A file read, shell command, notification, tray icon, or window operation usually needs:

- a frontend-callable command,
- a typed payload contract,
- capability policy,
- resource scope validation,
- platform-specific implementation,
- lifecycle cleanup.

Plugins package those responsibilities behind one interface.

Built-in plugins and custom plugins use the same lifecycle model.

## Register A Built-In Plugin

```crystal
require "crystkit"

config = CrystKit::AppConfig.new(
  capabilities_manifest: Path["capabilities.json"],
)

app = CrystKit::App.new(config)

app.plugin CrystKit::Plugins::Dialog.new
app.plugin CrystKit::Plugins::FS.new

app.window(title: "Notes", html: File.read("frontend/index.html"))
app.run
```

Frontend:

```js
const path = await ipc.invoke("dialog.open_file", { title: "Open note" });
const content = await ipc.invoke("fs.read_text", { path });
```

The plugin registers the commands. Plugin metadata declares what those commands need. The app manifest grants authority and scopes resources.

## Plugin Lifecycle

When you call `app.plugin MyPlugin.new`, the registry runs this sequence:

1. Validate the plugin identifier.
2. Validate metadata: `metadata.id` must match `plugin.identifier`, no duplicate commands/events, capability identifiers match `[a-zA-Z0-9_:.-]+`.
3. Check declared dependencies.
4. Register plugin metadata. When **no** capabilities manifest is loaded, the plugin's declared capabilities are also auto-granted (demo mode). When a manifest is loaded, plugins only _declare_ capabilities — the manifest (or `app.grant`) is the sole source of authority. See [Security](security.md#plugin-capabilities-with-and-without-a-manifest).
5. Declare `frontend_events` with the router so the frontend can emit them.
6. Call `initialize_plugin(context)`.
7. Validate registered commands match declared metadata.
8. Register IPC policy with the router.

Separately, during the application lifecycle:

9. `on_window_created` is called by `App` (not the registry) for each new window.
10. `cleanup_plugin` is called by `Registry#cleanup_all` during shutdown, in reverse registration order.

This lifecycle is why plugins should register commands through `Plugin::Context`, not by mutating the router directly.

## `Plugin::Base`

A plugin extends `CrystKit::Plugin::Base`:

```crystal
class GreeterPlugin < CrystKit::Plugin::Base
  def identifier : String
    "greeter"
  end

  def metadata : CrystKit::Plugin::Metadata
    CrystKit::Plugin::Metadata.new(
      id: identifier,
      commands: ["greeter.hello"],
    )
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.command "greeter.hello", String do |name|
      "Hello, #{name}"
    end
  end

  def cleanup_plugin : Nil
  end
end
```

Register it:

```crystal
app.plugin GreeterPlugin.new
```

Invoke it:

```js
await ipc.invoke("greeter.hello", "Crystal");
```

## Plugin Context

`Plugin::Context` gives a plugin access to runtime services:

| Context Access    | Use                                               |
| ----------------- | ------------------------------------------------- |
| `app`             | Coordinate with the owning `CrystKit::App`.       |
| `router`          | Lower-level command and event access.             |
| `capabilities`    | Check or request capabilities.                    |
| `scopes`          | Validate or persist resource scopes.              |
| `config`          | Read plugin-specific config from `crystkit.json`. |
| `command`         | Register plugin-owned commands.                   |
| `emit`            | Emit a backend event to frontends.                |
| `listen`          | Subscribe to a frontend-emitted event.            |
| `command_context` | Register a context-aware command.                 |

Prefer `context.command` for plugin IPC. The registry uses it to track command ownership and validate metadata.

## Metadata

Metadata describes the plugin to the registry and router.

```crystal
def metadata : CrystKit::Plugin::Metadata
  ipc = CrystKit::IPC::PolicyCatalog.new
    .path("notes.read", "fs:read", "path", IPC::ResourcePermission::Read)
    .path("notes.write", "fs:write", "path", IPC::ResourcePermission::Write)

  CrystKit::Plugin::Metadata.new(
    id: "notes",
    commands: ["notes.read", "notes.write"],
    events: ["notes:changed"],
    capabilities: ["fs:read", "fs:write"],
    ipc: ipc,
  )
end
```

Important fields:

| Field             | Purpose                                                                                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `identifier`      | Unique plugin ID.                                                                                                                                                                    |
| `commands`        | Commands the plugin is expected to register.                                                                                                                                         |
| `events`          | Events the plugin emits (backend → frontend). Validated by `context.emit` — the plugin can only emit listed events. **Not** frontend-emittable.                                      |
| `frontend_events` | Events the frontend is allowed to emit that this plugin listens to (frontend → backend). Declared with the router during registration so `ipc.emit(name, ...)` from JS is permitted. |
| `capabilities`    | Capabilities the plugin contributes to the runtime.                                                                                                                                  |
| `dependencies`    | Other plugin identifiers that must already be registered.                                                                                                                            |
| `ipc`             | Command policy used for frontend authorization.                                                                                                                                      |

The split between `events` and `frontend_events` enforces event direction security: a plugin's backend-emitted events (like `menu.click`, `fs.changed`) cannot be spoofed by the frontend. Only events explicitly listed in `frontend_events` can be emitted from JavaScript.

Registered commands must match metadata. This keeps plugin documentation, security policy, and runtime behavior aligned.

## IPC Policy

Plugin IPC policy tells the router how to authorize frontend calls before handlers run.

```crystal
ipc = CrystKit::IPC::PolicyCatalog.new
  .public("greeter.hello")
  .path("fs.read_text", "fs:read", "path", Permission::Read)
  .path("fs.write_text", "fs:write", "path", Permission::Write)
  .resource("http.request", "http:request", "url")
```

Policy helpers:

| Helper                                             | Check                                                           |
| -------------------------------------------------- | --------------------------------------------------------------- |
| `public(command)`                                  | No capability check. Use only for harmless commands.            |
| `require(command, capability)`                     | Capability only.                                                |
| `path(command, capability, json_path, permission)` | Capability plus filesystem/path scope.                          |
| `resource(command, capability, json_path)`         | Capability plus non-file resource scope such as URL or command. |

The policy does not grant authority by itself. The application still grants authority through code or `capabilities.json`.

## Plugin Configuration

Plugin-specific config lives in `crystkit.json`:

```json
{
  "plugins": {
    "notes": {
      "default_directory": "~/Documents/Notes"
    }
  }
}
```

The plugin reads it from context:

```crystal
def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
  default_directory = context.config["default_directory"]?.try(&.as_s?)

  context.command "notes.default_directory" do
    default_directory || ""
  end
end
```

Keep security decisions in capabilities and IPC policy. Use plugin config for feature behavior.

## Built-In Plugin Areas

CrystKit includes built-in plugins for common desktop capabilities. The exact command list is source-backed — see `src/plugins/builtins/` for the authoritative list. The categories below explain how to choose the right area.

| Area                 | Examples                                                                                             |
| -------------------- | ---------------------------------------------------------------------------------------------------- |
| Files and storage    | Filesystem, file watching, SQLite/database, key-value store, safe storage.                           |
| Networking           | HTTP, WebSocket, custom protocols, certificate pinning, local server.                                |
| Process execution    | Process spawning, shell commands, sidecars.                                                          |
| Desktop integration  | Dialogs, notifications, tray, menus, context menus, clipboard, shortcuts.                            |
| Speech               | Voice discovery and synthesis; recognition languages, permissions, lifecycle, and transcript events. |
| Window integration   | Window state, titlebar, toolbar, positioning, effects, drag/drop, taskbar progress.                  |
| System information   | Hardware, display manager, system info, power monitor, idle monitor, DPI monitor.                    |
| Application behavior | Autostart, single instance, deep links, updater, logging, devtools.                                  |
| Platform-specific UI | NSPanel and other specialized window features.                                                       |

When choosing a built-in plugin, ask:

1. Does the frontend need to initiate the action?
2. Which command does it need to invoke?
3. Which capability does that command require?
4. Which resource scope should constrain it?
5. Which windows should be allowed to use it?

That sequence keeps feature use connected to the security model.

### Speech plugin

`CrystKit::Plugins::Speech` keeps text-to-speech and speech-to-text under
separate capabilities. An application can grant `speech:synth` without
granting microphone recognition through `speech:recognize`.

| Capability         | Commands                                                                                                                                                                                                                                    |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `speech:synth`     | `speech.list_voices`, `speech.speak`, `speech.stop`, `speech.pause`, `speech.resume`, `speech.speaking`                                                                                                                                     |
| `speech:recognize` | `speech.recognize_languages`, `speech.recognize_available`, `speech.recognize_permission`, `speech.recognize_request_permission`, `speech.recognize_start`, `speech.recognize_stop`, `speech.recognize_abort`, `speech.recognize_listening` |

Recognition emits `speech.recognition_result`,
`speech.recognition_error`, and `speech.recognition_end`. Results contain
`transcript`, `final`, and nullable `confidence` fields.

```js
const { languages } = await ipc.invoke("speech.recognize_languages");
const language = languages.includes("en-US") ? "en-US" : languages[0];

if (language) {
  await ipc.invoke("speech.recognize_request_permission");
  await ipc.invoke("speech.recognize_start", [language, true]);
}

ipc.listen("speech.recognition_result", ({ transcript, final, confidence }) => {
  console.log({ transcript, final, confidence });
});
```

The language list reports system-supported BCP 47 tags; current availability
can still change. Linux returns an empty list because it has no standard
OS-native STT service. Packaged macOS applications must set
`bundle.macos_microphone_usage_description` and
`bundle.macos_speech_recognition_usage_description` in `crystkit.json`.

## Custom Plugin With Capability Policy

```crystal
class ExportPlugin < CrystKit::Plugin::Base
  def identifier : String
    "export"
  end

  def metadata : CrystKit::Plugin::Metadata
    ipc = CrystKit::IPC::PolicyCatalog.new
      .path("export.markdown", "fs:write", "path", IPC::ResourcePermission::Write)

    CrystKit::Plugin::Metadata.new(
      id: identifier,
      commands: ["export.markdown"],
      capabilities: ["fs:write"],
      ipc: ipc,
    )
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.command "export.markdown", ExportRequest do |request|
      File.write(request.path, request.content)
      true
    end
  end
end

struct ExportRequest
  include JSON::Serializable

  getter path : String
  getter content : String
end
```

The frontend call:

```js
await ipc.invoke("export.markdown", {
  path: "/Users/alice/Documents/note.md",
  content: markdown,
});
```

will be checked for `fs:write` and write permission on `path` before the handler runs.

## Dependencies

Plugins can depend on other plugins:

```crystal
def metadata : CrystKit::Plugin::Metadata
  CrystKit::Plugin::Metadata.new(
    id: "notes-sync",
    dependencies: ["http", "fs"],
    commands: ["notes_sync.run"],
  )
end
```

Register dependencies first:

```crystal
app.plugin CrystKit::Plugins::HTTP.new
app.plugin CrystKit::Plugins::FS.new
app.plugin NotesSyncPlugin.new
```

The registry rejects missing dependencies so plugin initialization order remains predictable.

## Cleanup

Use `cleanup_plugin` for resources owned by the plugin:

```crystal
def cleanup_plugin : Nil
  @watcher.try(&.stop)
  @server.try(&.close)
end
```

CrystKit calls cleanup during runtime shutdown in reverse registration order. The registry then removes plugin commands and event subscriptions.

## Features Versus Plugins

The source tree has both `features/` and `plugins/`.

- A **feature** implements native or reusable behavior.
- A **plugin** exposes behavior to the CrystKit runtime, usually through IPC and metadata.

Application code can use a feature directly when all behavior stays in Crystal. Use a plugin when frontend code needs to call it, when capability policy matters, or when you want lifecycle and configuration through the plugin registry.

## Next

Read [Windows](windows.md) next if your plugin behavior depends on which window made a request or if the app needs multiple windows with different authority.

Use [Security](security.md) when adding privileged commands, and [IPC](ipc.md) when designing command payloads and event flows.
