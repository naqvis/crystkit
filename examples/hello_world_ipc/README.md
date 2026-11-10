# Hello World IPC

The minimum viable Crystal Webview app. Demonstrates:

- Constructing a `CrystKit::App`
- Granting capabilities
- Registering a typed `command` (`greet`) with one parameter
- Registering a no-parameter command (`get_time`)
- Listening to a frontend-emitted event (`frontend:ping`)
- Emitting a backend event back to the frontend (`server:tick`)
- Mirroring backend-owned reactive state (`counter`)
- Single-window setup with inline HTML

## Run

```bash
crystal run examples/hello_world_ipc/main.cr
```

## What you'll see

A 800×600 window with four buttons:

- **Greet** — calls `ipc.invoke("greet", "Developer")`. The Crystal handler returns `"Hello, Developer! …"` which appears in the result panel.
- **Server time** — calls `ipc.invoke("get_time", {})`. Returns the current UTC time.
- **Trigger backend event** — calls `ipc.emit("frontend:ping", {...})`. The Crystal listener prints to the terminal and emits `server:tick` back to the frontend, which appears in the events panel.
- **Increment reactive state** — calls `ipc.invoke("counter.increment", {})`. The Crystal handler mutates the backend `counter` state slice; the frontend counter display updates through `ipc.state("counter")`, not a custom event.

## How it works

```crystal
app.command "greet", String do |name|
  "Hello, #{name}! Greetings from Crystal."
end
```

The `command` macro registers a JSON-validated handler. Parameters are decoded into typed Crystal values before the block runs. The return value is auto-coerced to JSON.

```crystal
app.on("frontend:ping") do |payload|
  app.emit("server:tick", {"echo" => payload, "time" => Time.utc.to_s})
end
```

`app.on` subscribes to events from any source (frontend or backend). `app.emit` delivers to all subscribers and bridges to the frontend's `__CRYSTKIT_IPC__.listen` callbacks.

```crystal
counter = app.state("counter", CounterState) { CounterState.new(0) }

app.command "counter.increment" do
  counter.update do |state|
    state.count += 1
    state
  end
  counter.value.count
end
```

`app.state` declares backend-owned state that frontend code can mirror. The
`update` block is the observed transaction: CrystKit serializes the state
before and after the block, computes JSON Patch, and pushes the patch to
attached frontend state refs.

## Frontend

`window.__CRYSTKIT_IPC__` is auto-injected by the framework on every page:

```js
const ipc = window.__CRYSTKIT_IPC__;

await ipc.invoke("greet", "Developer"); // Promise<string>
ipc.emit("frontend:ping", { message: "ping" }); // fire-and-forget
ipc.listen("server:tick", (payload) => render(payload));

const counter = await ipc.state("counter");
counter.subscribe((state) => renderCounter(state.count));
```

## Next steps

- [`file_manager/`](../file_manager) — adds the FS and Dialog plugins
- [`note_taking_app/`](../note_taking_app) — adds persistent storage
- [`docs/ipc.md`](../../docs/ipc.md) — full IPC reference
