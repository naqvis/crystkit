# CrystKit

**Native desktop applications in Crystal, with a web frontend and a runtime that owns the hard parts.**

CrystKit is a desktop application framework for Crystal. It gives you a native window backed by the system WebView, typed IPC between Crystal and JavaScript, capability-based security, 50+ built-in native feature plugins, multi-window lifecycle management, reactive state slices, async streaming channels, and a builder CLI for development and distribution.

The framework is built around one object:

```crystal
app = CrystKit::App.new
```

That `App` is the composition root for the desktop runtime. It owns the IPC router, security context, plugin registry, window registry, lifecycle hooks, reactive state, and platform services your application uses.

| Platform | Native WebView    |
| -------- | ----------------- |
| macOS    | Cocoa / WebKit    |
| Linux    | GTK 3 / WebKitGTK |
| Windows  | Win32 / WebView2  |

## Why CrystKit

The web is the most productive way to build a UI. The system WebView renders it natively — no bundled Chromium, no Electron-sized memory footprint. Crystal on the backend gives you type safety, fast native I/O, and a single compile-to-binary story.

What CrystKit adds on top of that combination:

- **Typed IPC** — Crystal command signatures define the payload shape JavaScript must send. Responses and failures cross the boundary in predictable envelopes. No `any`-typed `invoke` chaos.
- **Capability security** — Native operations require explicit capabilities and may be restricted by resource scopes and per-window grants. The framework enforces it at the IPC boundary, not in documentation.
- **50+ built-in plugins** — File system, dialogs, clipboard, notifications, system tray, global shortcuts, HTTP, WebSocket, safe storage, biometric auth, printing, speech synthesis and recognition, process management, window effects, auto-updater, and more. All gated by the same capability model.
- **Reactive state slices** — The backend owns state; the frontend subscribes to diffs. `app.state("settings", Settings) { ... }` emits JSON Patch on every `#update`. No manual invoke/listen/event-name glue.
- **Streaming channels** — `IPC::Channel(T)` pushes ordered values from backend to frontend after a command returns. The frontend attaches with `ipc.channel(id).onData(...)`. Built for log tails, process stdout, live metrics.
- **Builder CLI** — `crystkit init` scaffolds a project, `crystkit dev` runs with hot reload, `crystkit build` compiles, `crystkit bundle` packages for distribution.

## A Minimal App

```crystal
require "crystkit"

app = CrystKit::App.new

app.plugin(CrystKit::Plugins::FS.new)
app.plugin(CrystKit::Plugins::Dialog.new)
app.scopes.persist("~", CrystKit::Security::Permission::Write)

app.window(title: "Notes", width: 800, height: 600, html: <<-HTML)
  <input id="path" placeholder="~/note.txt">
  <textarea id="body" placeholder="Write..."></textarea>
  <button onclick="save()">Save</button>
  <script>
    const ipc = window.__CRYSTKIT_IPC__;
    async function save() {
      const p = path.value || await ipc.invoke("dialog.save_file", { title: "Save note" });
      if (!p) return;
      await ipc.invoke("fs.write_text", { path: p, content: body.value });
      alert("Saved");
    }
  </script>
HTML

app.run
```

The frontend calls the FS plugin's `fs.write_text` command and the Dialog plugin's `dialog.save_file` command through the injected bridge. Both are gated by capabilities and scopes — `fs:write` requires a write scope for the path, `dialog:save` requires the `dialog:save` capability. That's the whole model: **plugins expose native features as IPC commands, the frontend calls them through the bridge, capabilities and scopes enforce what's allowed.**

## Plugins vs Features

CrystKit has two layers of native capability:

**Plugins** are the frontend-facing layer — they register IPC commands the frontend calls through the bridge (`fs.write_text`, `dialog.save_file`, …), gated by capabilities and scopes. Most apps use plugins for native access.

**Features** are the backend-facing layer — Crystal classes you instantiate directly when the backend needs to do native work itself. Features bypass IPC entirely; they're just Crystal API.

Plugins are the common entry point. Features are there when you need the same native capability directly in Crystal. Both share the same security context: capabilities and scopes apply either way.

## Reactive State in 10 Lines

Backend owns state, frontend subscribes to diffs:

```crystal
class Counter
  include JSON::Serializable
  property count : Int32 = 0
  def initialize(@count = 0); end
end

counter = app.state("counter", Counter) { Counter.new }

# Backend mutates — frontend gets a JSON Patch automatically
counter.update { |c| c.count += 1; c }
```

```js
const counter = await ipc.state("counter");
console.log(counter.value.count); // 0
counter.subscribe((v) => console.log(v.count)); // 1, 2, 3...
```

No `invoke` for the initial value, no `listen` for changes, no event-name coordination. One attach, one subscribe.

## Streaming in 10 Lines

Backend pushes a stream, frontend consumes it:

```crystal
fs = CrystKit::Features::FileSystem.new(app.security)

app.command "log.tail", String do |path|
  ch = CrystKit::IPC::Channel(String).new(app.router)
  spawn do
    fs.open_read(Path[path]) { |io| io.each_line { |line| ch.send(line) } }
    ch.close
  end
  {"channel_id" => ch.id}
end
```

```js
const { channel_id } = await ipc.invoke("log.tail", "/var/log/app.log");
ipc
  .channel(channel_id)
  .onData((line) => appendToUI(line))
  .onEnd(() => console.log("done"));
```

The frontend gets ordered delivery with lifecycle management. No slurping, no polling.

## The Framework Model

| Responsibility      | What it means in an app                                                                                                                       |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Runtime ownership   | `CrystKit::App` creates and owns windows, plugins, IPC, security, platform services, reactive state, and shutdown.                            |
| Typed IPC           | Crystal command signatures define the payload shape JavaScript must send. Responses and failures cross the boundary in predictable envelopes. |
| Capability security | Native operations require explicit capabilities and may be restricted by resource scopes and per-window grants.                               |
| Native plugins      | 50+ built-in plugins expose native features through the same command, metadata, lifecycle, and policy model.                                  |
| Reactive state      | Backend-owned state slices emit JSON Patch diffs to frontend subscribers on every `#update`.                                                  |
| Streaming           | `IPC::Channel(T)` pushes ordered values from backend to frontend after a command returns.                                                     |
| Builder workflow    | The CLI scaffolds projects, serves frontend assets, builds Crystal binaries, and bundles apps for distribution.                               |

Those responsibilities are connected. A frontend call to `fs.read_text` is not "just a file read" — it's a typed IPC request, routed through plugin metadata, checked against capabilities and filesystem scopes, executed by a native feature, and returned to the window that invoked it.

## Examples

See [`examples/`](examples/) — minimal demos, full applications, and a feature catalog. Start with [`examples/README.md`](examples/README.md) for the learning path.

## Start Reading

1. [Getting started](guides/getting-started.md) — build the smallest complete app and see it run.
2. [Plugins](guides/plugins.md) — add native features (dialogs, clipboard, FS, tray, notifications) with built-in plugins.
3. [IPC](guides/ipc.md) — understand the boundary you've been using: typed commands, events, channels, reactive state.
4. [Windows](guides/windows.md) — multi-window apps, lifecycle, labels, parent-child.
5. [Security](guides/security.md) — capabilities, scopes, manifests, and runtime prompts.
6. [Recipes](guides/recipes.md) — common patterns: reactive state, streaming, shutdown veto, tray menus.
7. [Architecture](guides/architecture.md) — the runtime internals, for when you want to understand why it works.
8. [Testing](guides/testing.md) — verify and diagnose with the `FakeFrontend` harness.
9. [Cross-platform](guides/cross-platform.md) — platform support matrix.

For CLI usage (`init`, `dev`, `build`, `bundle`), run `crystkit --help`.

## Installation

Add CrystKit to `shard.yml`:

```yaml
dependencies:
  crystkit:
    github: naqvis/crystkit
```

Install dependencies:

```sh
shards install
```

Native prerequisites:

- **macOS:** WebKit is provided by the system. You need the normal macOS developer toolchain used to compile native shards.
- **Linux:** Install the development packages for GTK 3, WebKitGTK, GLib/GIO, X11, DBus, libnotify, appindicator, udev, libsecret, speech-dispatcher, and OpenSSL. See [Getting started](guides/getting-started.md) for distro package names.
- **Windows:** Install Visual Studio C++ Build Tools and the `Microsoft.Web.WebView2` SDK package. Windows 11 includes the Evergreen WebView2 Runtime; install it separately only on machines where it is missing.

## Development

Build the CLI from the `builder/` folder (it avoids the runtime's native dependencies and keeps its own minimal dependency set):

```sh
cd builder
shards install
shards build --release
```

Run the full test suite (headless — no display or native webview required):

```sh
crystal spec
```

## Contributing

1. Fork it (<https://github.com/naqvis/crystkit/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License

MIT

## Contributors

- [Ali Naqvi](https://github.com/naqvis) - creator and maintainer
