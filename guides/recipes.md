# Recipes

Practical patterns for building CrystKit applications.

## App setup

### Minimal app

```crystal
require "crystkit"

CrystKit::App.run do |app|
  app.window title: "Hello", html: "<h1>Hello, world!</h1>"
end
```

### App with configuration

```crystal
config = CrystKit::AppConfig.new(
  name: "MyApp",
  version: "1.0.0",
  identifier: "com.example.myapp",
  csp: "default-src 'self'",
)

CrystKit::App.run(config) do |app|
  app.window title: "MyApp", label: "main", html: "<h1>Welcome</h1>"
end
```

### App with plugins

```crystal
require "crystkit"
require "crystkit/plugins/builtins"

app = CrystKit::App.new
app.plugin CrystKit::Plugins::FS
app.plugin CrystKit::Plugins::Dialog
app.plugin CrystKit::Plugins::Window
app.plugin CrystKit::Plugins::Store

main = app.window title: "My App", label: "main", html: File.read("frontend/index.html")
app.run
```

## Command patterns

### Zero-arg command (health check)

```crystal
app.command "ping" { {"pong" => true} }
```

```js
const result = await ipc.invoke("ping");
```

### Single-typed-arg command

```crystal
app.command "reverse", String do |text|
  text.reverse
end
```

```js
await ipc.invoke("reverse", "hello");
```

### Multi-arg command

```crystal
app.command "multiply", Float64, Float64 do |a, b|
  a * b
end
```

```js
await ipc.invoke("multiply", [3.5, 2.0]);
```

### Structured request command

```crystal
struct CreateNote
  include JSON::Serializable
  getter title : String
  getter body : String
  getter tags : Array(String)
end

app.command "notes.create", CreateNote do |note|
  {"title" => note.title, "body" => note.body, "tags" => note.tags}
end
```

```js
await ipc.invoke("notes.create", {
  title: "Meeting notes",
  body: "Discussed Q3 roadmap",
  tags: ["work", "meeting"]
});
```

### Context-aware command

Use `command_context` inside a plugin's `initialize_plugin` to receive the `IPC::Context` (calling window, security context, plugin id, frontend flag):

```crystal
class MyPlugin < CrystKit::Plugin::Base
  def identifier : String; "my-plugin"; end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.command_context "my.info" do |ctx, _params|
      {"window" => ctx.window.try(&.id), "frontend" => ctx.frontend?}
    end
  end
end
```

## Event patterns

### Frontend → Backend event

```crystal
app.on("ui:dark_mode") do |payload|
  theme = payload["enabled"].as_bool
  apply_dark_mode(theme)
end
```

```js
ipc.emit("ui:dark_mode", { enabled: true });
```

### Backend → Frontend broadcast

```crystal
app.command "data.refresh" do
  fresh = fetch_data()
  app.emit("data:updated", fresh)
  "ok"
end
```

```js
const off = ipc.listen("data:updated", (data) => {
  renderData(data);
});
```

### Cross-window broadcast

```crystal
# Emitted to ALL windows automatically via App#emit
app.emit("global:notification", {"text" => "File saved"})
```

### Targeted window event (low-level)

```crystal
# Send to a specific window's frontend only
app.emit("private:msg", payload, target: window)
```

## Window patterns

### Splash screen

```crystal
splash = app.window(
  CrystKit::Core::WindowOptions.new(title: "Loading", width: 480, height: 320, frameless: true),
  html: File.read("splash.html"),
)

spawn do
  sleep 2
  splash.hide
  main = app.window(title: "App", label: "main", html: File.read("app.html"))
  main.show
end
```

### Settings window (frameless + modal)

```crystal
app.command "settings.open" do
  settings = app.window(
    CrystKit::Core::WindowOptions.new(
      title: "Settings", width: 600, height: 400,
      frameless: true, modal: true, label: "settings",
    ),
    parent_label: "main",
    html: File.read("settings.html"),
  )
  settings.show
end
```

### Detached background window

```crystal
# Window that loads content but stays hidden
worker = app.window(
  title: "Worker", label: "worker",
  visible: false, url: "https://localhost:5173/worker.html",
)

# Communicate with it through events
app.emit("worker:process", {"task" => "sync"})
```

### Window management from frontend

```crystal
# Register the Window plugin
app.plugin CrystKit::Plugins::Window
```

```js
// Frontend window management
const info = await ipc.invoke("window.create", {
  label: "preview",
  title: "Preview",
  width: 400, height: 300,
  url: "https://example.com",
  modal: true,
});

await ipc.invoke("window.set_size", ["preview", 800, 600]);
await ipc.invoke("window.show", "preview");

// Close when done
await ipc.invoke("window.close", "preview");
```

## Data persistence patterns

### Key-value store (built-in)

```crystal
app.plugin CrystKit::Plugins::Store
```

```js
// Persist user settings
await ipc.invoke("store.set", ["preferences", "theme", "dark"]);
await ipc.invoke("store.set", ["preferences", "font_size", 14]);

// Read them back
const theme = await ipc.invoke("store.get", ["preferences", "theme"]);
const keys = await ipc.invoke("store.keys", "preferences");

// Delete
await ipc.invoke("store.delete", ["preferences", "temporary_flag"]);
await ipc.invoke("store.clear", "preferences");
```

### File-based persistence

```crystal
app.plugin CrystKit::Plugins::FS
app.plugin CrystKit::Plugins::Dialog
```

```js
// Save document via file dialog
const path = await ipc.invoke("dialog.save_file", {
  title: "Save Document",
  default_name: "untitled.txt",
});

if (path) {
  await ipc.invoke("fs.write_text", { path, content: "Hello, world!" });
}

// Open document
const file = await ipc.invoke("dialog.open_file", {
  title: "Open Document",
});

if (file) {
  const content = await ipc.invoke("fs.read_text", { path: file });
  document.getElementById("editor").value = content;
}
```

## Streaming patterns

### Progress reporting

```crystal
app.command "work.start" do
  channel = CrystKit::IPC::Channel(Int32).new(app.router)
  spawn do
    (0..100).step(10) do |pct|
      sleep 0.5
      channel.send(pct)
    end
    channel.close
  end
  {"channel_id" => channel.id}
end
```

```js
const { channel_id } = await ipc.invoke("work.start");
const bar = document.getElementById("progress");
ipc.channel(channel_id)
  .onData(pct => { bar.value = pct; })
  .onEnd(() => { console.log("Done!"); });
```

### Log streaming

```crystal
app.command "logs.tail" do
  channel = CrystKit::IPC::Channel(String).new(app.router)
  spawn do
    loop do
      line = read_next_log_line
      break unless line
      channel.send(line)
      sleep 0.1
    end
  rescue ex
    channel.close_with_error(ex.message)
  end
  {"channel_id" => channel.id}
end
```

### Streaming a large file

Compose `FileSystem#open_read` with `IPC::Channel` to stream a file line-by-line without loading it into memory:

```crystal
fs = CrystKit::Features::FileSystem.new(app.security)

app.command "file.stream_lines", String do |path|
  ch = CrystKit::IPC::Channel(String).new(app.router)
  spawn do
    fs.open_read(Path[path]) { |io| io.each_line { |line| ch.send(line) } }
    ch.close
  rescue ex : CrystKit::Core::Error
    ch.close_with_error(ex.message || "read failed")
  end
  {"channel_id" => ch.id}
end
```

```js
const { channel_id } = await ipc.invoke("file.stream_lines", "/var/log/app.log");
ipc.channel(channel_id)
  .onData(line => appendToUI(line))
  .onEnd(() => console.log("done"));
```

### Streaming with error

```crystal
channel = CrystKit::IPC::Channel(String).new(app.router)
channel.send("processing")
channel.close_with_error("Out of memory")
```

```js
ipc.channel(channelId)
  .onData(v => console.log(v))
  .onError(err => showError(err)); // "Out of memory"
```

## Reactive state patterns

### Backend-owned state with frontend subscriptions

The backend owns a state value; the frontend subscribes to diffs. Replaces the pattern of writing one command for the initial value, one event for changes, and frontend glue that manually combines `invoke` and `listen`.

```crystal
class Settings
  include JSON::Serializable
  property theme : String = "light"
  property font_size : Int32 = 14
  def initialize(@theme = "light", @font_size = 14); end
end

settings = app.state("settings", Settings) { Settings.new }

# Mutate inside #update — CrystKit computes the JSON Patch and pushes it
settings.update { |s| s.theme = "dark"; s.font_size = 16; s }
```

```js
const settings = await ipc.state("settings");
console.log(settings.value.theme); // "dark"
settings.subscribe(v => {
  document.body.dataset.theme = v.theme;
});
```

### Multiple state slices

Declare separate slices for separate UI concerns. Each emits its own patches.

```crystal
tabs = app.state("tabs", TabState) { TabState.new }
editor = app.state("editor.buffer", BufferState) { BufferState.new }
terminal = app.state("terminal.session.1", TerminalState) { TerminalState.new }
```

Frontend attaches to each independently:

```js
const tabs = await ipc.state("tabs");
const buffer = await ipc.state("editor.buffer");
```

This split is not just organizational — it is the recommended pattern for large or high-frequency state. CrystKit diffs each slice against its previous snapshot to emit a JSON Patch, so a monolithic slice re-serializes its entire tree on every `update` even when only one field changed. Independent slices keep each update (and each patch) small. See *Performance notes for large or high-frequency state* in the IPC guide.

## Security patterns

### Capability enforcement

```crystal
app.command "admin.sensitive" do
  app.capabilities.require!("admin:access")
  perform_admin_task
end
```

### Per-window capabilities

```crystal
# Grant capabilities only to the "main" window
app.capabilities.grant_to_window("clipboard:write_text", main_window.id)
```

### Temporary capability grants

```crystal
# Grant a sensitive capability for 5 minutes
app.capabilities.grant_temporary("fs:delete", 5.minutes)

# Grant temporarily to a specific window
app.capabilities.grant_temporary_to_window("shell:execute", window.id, 1.minute)
```

### Runtime capability prompting

```crystal
# Set up a prompt handler
app.capabilities.set_prompt_handler do |capability|
  puts "Requesting capability: #{capability}. Approve? (y/n)"
  gets.chomp.downcase == "y"
end

# Or use the full request object
app.capabilities.on_capability_request do |request|
  if request.capability.starts_with?("fs:")
    CrystKit::Security::CapabilityRequestOutcome::Approved
  else
    CrystKit::Security::CapabilityRequestOutcome::Denied
  end
end
```

### Filesystem scope enforcement

```crystal
app.command "fs.safe_read", String do |path|
  # This will raise SecurityError if path is outside scoped directories
  File.read(path)
end
```

### Parent-child capability inheritance

```crystal
# Child windows inherit capabilities from their parent
child = app.window(options, parent_label: "main")
# Child now has all capabilities of "main" window
```

## UI patterns

### Frameless window with custom titlebar

```crystal
win = app.window(
  CrystKit::Core::WindowOptions.new(title: "Modern UI", width: 1024, height: 768, frameless: true, label: "main"),
  html: File.read("ui.html"),
)
```

```html
<!-- ui.html -->
<div class="titlebar" data-drag-region>
  <span class="title">Modern UI</span>
  <button onclick="ipc.invoke('window.minimize', 'main')">─</button>
  <button onclick="ipc.invoke('window.maximize', 'main')">☐</button>
  <button onclick="ipc.invoke('window.close', 'main')">✕</button>
</div>
<div class="content">
  <h1>App content here</h1>
</div>

<style>
  .titlebar {
    -webkit-app-region: drag;
    height: 38px;
    background: #2c2c2c;
    display: flex;
    align-items: center;
    padding: 0 8px;
  }
  .titlebar button {
    -webkit-app-region: no-drag;
  }
</style>
```

### Drag-and-drop file open

```crystal
app.plugin CrystKit::Plugins::DragDrop

app.on("drag.drop") do |payload|
  files = payload["files"].as_a.map(&.as_s)
  files.each { |path| open_file(path) }
end
```

```js
// Frontend listens for drag-drop events
ipc.listen("drag.drop", (payload) => {
  console.log("Dropped files:", payload.files);
});
```

### Register file types

File associations are an app-owned Feature because the Crystal backend declares which documents the application handles:

```crystal
app.file_associations do |files|
  files.register(
    ".md",
    "text/markdown",
    "Markdown Document",
    "A Markdown source file"
  )

  files.on_open do |path|
    puts "Open #{path}"
  end
end
```

Registration adds the application to the operating system’s “Open With” choices without replacing the user’s default handler. The registration is persistent; application shutdown does not remove it. CrystKit stores the registration metadata under `AppConfig#storage_dir`, allowing a later application run to remove the same registration safely. Remove it explicitly when the application no longer supports that file type:

```crystal
app.file_associations.unregister(".md")
```

CrystKit receives OS file-open requests through its app-owned activation feature across supported desktop platforms. The activation stream normalizes URL, file, and second-instance deliveries and is available to frontend code through the activations plugin.

### System tray

```crystal
app.plugin CrystKit::Plugins::Tray
```

```js
await ipc.invoke("tray.create", {
  icon: "/path/to/icon.png",
  tooltip: "My App",
  menu: [
    { id: "show", label: "Show Window" },
    { id: "separator", type: "separator" },
    { id: "quit", label: "Quit" },
  ]
});

ipc.listen("tray.menu_click", (payload) => {
  if (payload.item_id === "show") {
    ipc.invoke("window.show", "main");
  }
  if (payload.item_id === "quit") {
    ipc.invoke("window.close", "main");
  }
});
```

## Error handling patterns

### Command error handling

```crystal
app.command "data.fetch" do
  raise CrystKit::Core::IPCError.new(
    "Failed to fetch data",
    code: "FETCH_FAILED",
    context: "data_service",
  )
end
```

```js
try {
  await ipc.invoke("data.fetch");
} catch (err) {
  console.error(err.code);    // "FETCH_FAILED"
  console.error(err.message); // "Failed to fetch data"
  console.error(err.details); // { command: "data.fetch", type: "IPCError" }
}
```

### Global error logging

```crystal
app.on("error:handler") do |payload|
  Log.error { "App error: #{payload["error"].as_s}" }
end
```

### Graceful shutdown

```crystal
server = HTTPServer.new(8080)

app.on_shutdown { server.stop }
```

Shutdown runs in this order:

1. Shortcuts stopped
2. Tray destroyed
3. Plugin cleanup (`cleanup_plugin` on each plugin, reverse load order)
4. Lifecycle hooks (`on_shutdown` blocks, reverse registration order) — `server.stop`
5. All windows destroyed
6. `MainThread` registry cleared

### Quit confirmation ("save changes?")

`App#on_before_quit` is an app-wide vetoable shutdown interceptor. Unlike per-window `Window#on_close` (which must return `Bool` synchronously), `on_before_quit` may return either `Bool` or `CrystKit::Future(Bool)`, so a handler can show a native dialog and wait for the user's answer before the quit proceeds. It runs only on a programmatic quit (`app.quit`, a "Quit" menu item, etc.); the OS close button still routes through `Window#on_close`.

```crystal
app.on_before_quit do
  future = CrystKit::Future(Bool).new
  # Resolve the future from any fiber (e.g. a native dialog callback on
  # the UI thread). Returning the future from the block tells CrystKit
  # to wait for the user's answer before terminating.
  prompt_save_dialog(on_decision: ->(saving : Bool) { future.resolve(saving) })
  future
end

# Safety: never wait forever for a forgotten dialog. An unresolved future
# after the configured timeout cancels the quit (defaults to no timeout).
app.before_quit_timeout = 30.seconds
```

Returning `false` (or a future that resolves `false`, or fails to resolve) cancels the quit and leaves the run loop alive. Returning `true`/a future that resolves `true` proceeds to `Window#terminate` and then `#shutdown`.

## Lifecycle patterns

### On-ready callback

```crystal
app.window title: "App", label: "main", html: "<h1>Loading...</h1>"

app.on_ready do |window|
  Log.info { "App started with primary window: #{window.id}" }
  window.navigate("https://localhost:5173")
end

app.run
```

### Startup initialization

```crystal
CrystKit::App.run do |app|
  app.plugin CrystKit::Plugins::FS
  app.plugin CrystKit::Plugins::Store

  app.window title: "My App", label: "main", html: index_html
end
```

### Self-run pattern

```crystal
CrystKit::App.run(config) do |app|
  app.grant("fs:read", "dialog:open")
  app.plugin CrystKit::Plugins::FS
  app.plugin CrystKit::Plugins::Dialog

  app.command "greet", String do |name|
    "Hello, #{name}!"
  end

  app.window title: "Demo", label: "main", html: File.read("index.html")
end
```

## Plugin combination patterns

### File editor with dialogs

```crystal
app.plugin CrystKit::Plugins::FS
app.plugin CrystKit::Plugins::Dialog
app.plugin CrystKit::Plugins::Store

app.command "editor.open" do
  path = CrystKit::Plugins::Dialog::OpenRequest.new(title: "Open file")
  result = ... # use dialog plugin
end
```

### Multi-window communication

```crystal
app.plugin CrystKit::Plugins::Window

app.command "broadcast", String do |message|
  app.emit("app:broadcast", {"msg" => message})
end
```

### Clipboard integration

```crystal
app.plugin CrystKit::Plugins::Clipboard
```

```js
await ipc.invoke("clipboard.write_text", "Copied text");
const text = await ipc.invoke("clipboard.read_text");
```

## Frontend framework integration

### Vanilla JavaScript

```js
const { invoke, listen, emit } = window.__CRYSTKIT_IPC__;
```

### TypeScript minimal types

```typescript
interface StateRef<T> {
  readonly name: string;
  readonly value: T;
  subscribe(handler: (value: T) => void): () => void;
}

interface CrystKitIPC {
  invoke<T = unknown>(command: string, payload?: unknown): Promise<T>;
  listen(event: string, handler: (payload: unknown) => void): () => void;
  emit(event: string, payload?: unknown): void;
  channel(channelId: string): {
    onData(fn: (data: unknown) => void): unknown;
    onEnd(fn: () => void): unknown;
    onError(fn: (err: string) => void): unknown;
    close(): void;
  };
  state<T = unknown>(name: string): Promise<StateRef<T>>;
}

declare const ipc: CrystKitIPC;
```

### Vite dev server

```crystal
config = CrystKit::AppConfig.new
app = CrystKit::App.new(config)

# In dev, serve from Vite; in production, inline the HTML
if ENV["CRYSTKIT_ENV"]? == "development"
  app.window title: "App", url: "http://localhost:5173"
else
  app.window title: "App", html: File.read("dist/index.html"), label: "main"
end
```

## See Also

- `crystkit --help` — build and bundle commands
- [Security](security.md) — capabilities and scopes
- [Plugins](plugins.md) — built-in plugins
