# IPC

IPC is the boundary between the JavaScript frontend and the Crystal runtime. CrystKit makes that boundary explicit: Crystal registers commands, the frontend invokes them through an injected bridge, and the router decodes payloads based on the registered Crystal signature.

Read [Architecture](architecture.md) first if you have not already. This guide zooms into the router and bridge described there.

## The Bridge

Every CrystKit-created window receives an injected bridge:

```js
const ipc = window.__CRYSTKIT_IPC__;
```

The bridge exposes:

| Method | Purpose |
| --- | --- |
| `invoke(command, payload)` | Call a Crystal command and await a result. |
| `listen(event, handler)` | Subscribe to backend-emitted events. |
| `emit(event, payload)` | Emit a declared frontend event to Crystal. |
| `channel(id)` | Attach to a stream returned by a command. |
| `state(name)` | Attach to a backend-owned reactive state slice. |

The bridge exists inside CrystKit windows. It is not available when opening the HTML file in a normal browser tab.

## Commands

A command is a named Crystal handler:

```crystal
app.command "greet", String do |name|
  "Hello, #{name}"
end
```

The frontend invokes it:

```js
const message = await ipc.invoke("greet", "Crystal");
```

Command names must use dot-separated namespaces for application and plugin commands — the router rejects names containing a colon:

```text
notes.save
fs.read_text
dialog.open_file
window.show
```

Events commonly use colon-separated names:

```text
notes:saved
ui:ready
app:shutdown
```

## Payload Shapes

The Crystal command signature defines what the frontend must send.

### No Parameters

```crystal
app.command "app.version" do
  "0.1.0"
end
```

```js
await ipc.invoke("app.version");
```

### One Typed Parameter

One type consumes the complete payload.

```crystal
app.command "greet", String do |name|
  "Hello, #{name}"
end
```

```js
await ipc.invoke("greet", "Crystal");
```

For structured data, define a serializable type:

```crystal
struct SaveNote
  include JSON::Serializable

  getter path : String
  getter content : String
end

app.command "notes.save", SaveNote do |note|
  File.write(note.path, note.content)
  true
end
```

```js
await ipc.invoke("notes.save", {
  path: "/tmp/note.md",
  content: "# Notes"
});
```

### Multiple Typed Parameters

Multiple parameters consume an ordered JSON array.

```crystal
app.command "math.add", Int32, Int32 do |a, b|
  a + b
end
```

```js
await ipc.invoke("math.add", [2, 3]);
```

Use structured request types for commands that are likely to grow. Positional arguments are best for small stable operations.

### Context-Aware Commands

Some commands need request context, such as the invoking window. The context-aware form is available on `Plugin::Context` and `IPC::Router`, not directly on `App`:

```crystal
# Inside a plugin:
def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
  context.command_context "window.current_label" do |ctx, _params|
    ctx.window.try(&.label) || ""
  end
end
```

Or directly on the router:

```crystal
app.router.command_context "window.current_label" do |ctx, _params|
  ctx.window_authority_id
end
```

`IPC::Context` exposes `window : Core::Window?` and `window_authority_id : String?`. Use this sparingly. Most application commands should express their contract through typed payloads.

## Events

Commands are request/response. Events are notifications.

### Backend To Frontend

Crystal can emit to every frontend:

```crystal
app.emit("notes:saved", {"path" => "/tmp/note.md"})
```

Frontend code can listen:

```js
const unsubscribe = ipc.listen("notes:saved", (event) => {
  console.log(`Saved ${event.path}`);
});

unsubscribe();
```

Target a specific window when only one frontend should receive the event:

```crystal
app.emit("notes:saved", {"path" => path}, target: app.window_registry.find?("main"))
```

### Frontend To Backend

Events the frontend is allowed to emit must be declared on the backend. There are two declaration paths:

- **App-level**: `App#on(event)` both subscribes and declares the event as frontend-emittable.
- **Plugin-level**: `Plugin::Metadata#frontend_events` declares events the plugin will listen to via `context.listen`. The registry declares them with the router during plugin registration.

The router rejects undeclared frontend events with `IPC_POLICY_MISSING`. This prevents malicious frontend code from spoofing backend-originated events like `menu.click` or `fs.changed`.

```crystal
# App-level: subscribe + declare in one call
app.on("ui:ready") do |_payload|
  app.emit("app:ready", {"time" => Time.utc.to_s})
end
```

```js
ipc.emit("ui:ready");
```

```crystal
# Plugin-level: declare in metadata, listen in initialize_plugin
def metadata : CrystKit::Plugin::Metadata
  CrystKit::Plugin::Metadata.new(
    id: "stats",
    commands: %w(stats.summary),
    events: %w(stats:digest),            # backend emits this
    frontend_events: %w(__stats:call__), # frontend emits this
  )
end

def initialize_plugin(context) : Nil
  context.listen("__stats:call__") do |payload|
    # handle frontend-emitted event
  end
end
```

Use events for notifications. Use commands when the frontend needs a result.

## Reactive State

Use `App#state` when the Crystal backend owns a piece of state and the frontend should mirror it automatically. This replaces the common pattern of writing one command for the initial value, one event for changes, and frontend glue that manually combines `invoke` and `listen`.

Backend state values are ordinary Crystal objects. They only need to serialize through the same IPC codec used by command return values.

```crystal
class SettingsState
  include JSON::Serializable

  property theme : String
  property sidebar_width : Int32
  property notifications : Bool

  def initialize(@theme, @sidebar_width, @notifications)
  end
end

settings = app.state("settings", SettingsState) do
  SettingsState.new("light", 240, true)
end

settings.update do |state|
  state.theme = "dark"
  state.sidebar_width = 280
  state
end
```

The `update` block is the transaction boundary. CrystKit serializes the state before and after the block, computes JSON Patch, and pushes that patch over a private bridge channel. You do not define an app command, event name, delta type, parent class, mixin, or property macro.

Frontend code attaches through the injected bridge:

```ts
type SettingsState = {
  theme: string;
  sidebar_width: number;
  notifications: boolean;
};

const ipc = window.__CRYSTKIT_IPC__;
const settings = await ipc.state<SettingsState>("settings");

document.body.dataset.theme = settings.value.theme;

const unsubscribe = settings.subscribe((value) => {
  document.body.dataset.theme = value.theme;
});
```

Plain JavaScript uses the same runtime API without the type parameter:

```js
const settings = await window.__CRYSTKIT_IPC__.state("settings");
```

The returned state ref has:

| Member | Purpose |
| --- | --- |
| `name` | State slice name. |
| `value` | Current mirrored value. |
| `get()` | Returns the current mirrored value. |
| `subscribe(handler)` | Calls `handler(value)` after backend updates; returns an unsubscribe function. |

State slices are frontend-reactive by definition. Backend-only state should remain normal Crystal state outside `App#state`. For separate UI concerns, declare separate slices such as `settings`, `tabs`, `editor.buffer`, or `terminal.session.1`.

### Performance notes for large or high-frequency state

Each `update` serializes the state and diffs it against the previous snapshot to produce a JSON Patch — CrystKit does not require you to annotate your model or subclass a framework type, so it cannot track field-level changes without comparing whole snapshots. This keeps your business models plain (`JSON::Serializable` or ordinary structs), at the cost that a large slice pays a full serialization on every update.

To keep that cost bounded:

- **The previous snapshot is cached between updates**, so each `update` serializes the new value only once rather than twice. The default path is already roughly half the naive cost.
- **Prefer several small slices over one large slice.** A single monolithic object rewritten every tick re-serializes the entire tree each time, even if only a few fields changed. Splitting concerns into independent slices (`vitals.cpu`, `vitals.mem`, …) means each tick re-serializes only the slice that actually changed, and the frontend patch stays tiny. This is the recommended idiom for monitoring-style or high-frequency state — no framework magic, no model annotations required.

If your state is genuinely one large object that must be rewritten wholesale every tick, the cache is the entire realistic win; there is no framework option that avoids re-serializing it without binding your model to CrystKit-specific classes.

## Channels

Channels stream ordered values after a command returns a channel id. They are useful for long-running work such as progress updates, process output, file watching, or monitoring.

Backend:

```crystal
channel = CrystKit::IPC::Channel(JSON::Any).new(app.router)

app.command "jobs.start" do
  spawn do
    channel.send(JSON.parse(%({"status" => "started"})))
    channel.send(JSON.parse(%({"status" => "finished"})))
    channel.close
  end

  channel.id
end
```

Frontend:

```js
const channelId = await ipc.invoke("jobs.start");
const channel = ipc.channel(channelId);

channel.onData((value) => {
  console.log(value.status);
});

channel.onEnd(() => {
  console.log("done");
});
```

Channels can declare a target window via `Channel.new(router, target_window_id:)`. Owner-checking is available through `Router#authorize_frontend_channel!` but is not automatically enforced by the JS bridge.

## Errors And Envelopes

CrystKit wraps command results in response envelopes internally.

Success:

```json
{
  "ok": true,
  "value": "Hello, Crystal"
}
```

Failure:

```json
{
  "ok": false,
  "error": {
    "code": "COMMAND_NOT_FOUND",
    "message": "No command registered",
    "details": {}
  }
}
```

The JavaScript bridge resolves successful envelopes and rejects failed ones.

Common error codes:

| Code | Meaning |
| --- | --- |
| `COMMAND_NOT_FOUND` | No command is registered with that name. |
| `VALIDATION_ERROR` | Payload does not match the Crystal signature. |
| `PAYLOAD_TOO_LARGE` | Payload exceeds the router limit. |
| `TIMEOUT` | Command exceeded its configured timeout. |
| `CAPABILITY_DENIED` | Security rejected the command before handler execution. |
| `SCOPE_DENIED` | Resource scope validation failed. |
| `IPC_POLICY_MISSING` | Frontend emitted an event the backend did not declare, or referenced an unknown channel id. |

## Frontend Command Authority

Every `app.command` is callable from the frontend unless policy says otherwise. For public application commands, no capability check is needed:

```crystal
app.command "app.version" do
  "0.1.0"
end
```

Privileged commands should have explicit policy. Built-in and external plugins declare command policy in plugin metadata:

```crystal
ipc = CrystKit::IPC::PolicyCatalog.new
  .path("fs.read_text", "fs:read", "path", IPC::ResourcePermission::Read)
```

For application commands that need pre-handler router enforcement, declare the policy in `crystkit.json`:

```json
{
  "app": {
    "ipc": {
      "commands": {
        "notes.export": {
          "capability": "fs:write",
          "resource": "path",
          "resource_kind": "path",
          "permission": "write"
        }
      }
    }
  }
}
```

If no policy exists, the router treats the command as public. It does not infer capabilities from command names.

## Policy Resolution Flow

For a frontend invocation, the router resolves policy in this order:

1. Application config override in `app.ipc.commands`.
2. Plugin metadata registered with the plugin registry.
3. Public fallback.

If the policy is public, the handler runs after normal payload validation. If the policy requires a capability or resource, the security context checks the invoking window before the handler runs.

Backend Crystal calls are trusted application code and do not go through frontend IPC authorization.

## Plugin Commands

Plugins register commands through `Plugin::Context`:

```crystal
class GreeterPlugin < CrystKit::Plugin::Base
  def identifier : String
    "greeter"
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.command "greeter.hello", String do |name|
      "Hello, #{name}"
    end
  end
end
```

The registry tracks which plugin owns each command and validates that registered commands match plugin metadata.

## Next

Read [Security](security.md) next if your IPC commands touch native resources or need frontend authority checks.

Read [Plugins](plugins.md) next if you want to expose a native feature or build a reusable extension.
