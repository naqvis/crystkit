# Architecture

CrystKit is organized around runtime ownership. Your application creates one `CrystKit::App`; that app owns the desktop runtime and gives the rest of your code a stable place to register windows, commands, plugins, security rules, and lifecycle hooks.

This guide explains what CrystKit owns, what your application owns, and how a frontend request moves through the system.

## The Core Split

A CrystKit application has two kinds of responsibility:

| Your Application Owns               | CrystKit Owns                                                        |
| ----------------------------------- | -------------------------------------------------------------------- |
| Domain logic and data model         | Native window creation and lifecycle                                 |
| Crystal commands and event handlers | IPC routing, payload decoding, envelopes, and channels               |
| Frontend UI and interaction code    | JavaScript bridge injection and frontend/backend dispatch            |
| Which plugins are registered        | Plugin lifecycle, metadata validation, command ownership             |
| Which capabilities the app needs    | Capability checks, scopes, per-window restrictions, prompts          |
| Project configuration               | Builder config loading, schema generation, build and bundle workflow |

`CrystKit::App` is the boundary between those responsibilities.

## Layer Overview

CrystKit is built in distinct layers, each with a single concern. Reading top-to-bottom is the order a frontend request travels; bottom-to-top is the order the source tree depends on itself.

```text
┌──────────────────────────────────────────────────────────────────┐
│  Application code                                  │
│    app.command, app.window, app.plugin, app.run                  │
└───────────────────────────────┬──────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────┐
│  App + Runtime            src/app, src/core/runtime              │
│    Composition root; owns every subsystem                        │
└──────┬────────────┬─────────────┬───────────────┬─────────────────┘
       │            │             │               │
┌──────▼────┐ ┌─────▼─────┐ ┌────▼─────┐ ┌────────▼────────┐
│   IPC     │ │ Security  │ │ Plugins  │ │  Windows        │
│ src/ipc   │ │ src/      │ │ src/     │ │ src/core        │
│ Router    │ │ security  │ │ plugins  │ │ Window,         │
│ Channel   │ │ Context   │ │ Registry │ │ EnhancedWindow, │
│ JSBridge  │ │ Scopes    │ │ Builtins │ │ Registry,       │
│           │ │           │ │          │ │ MainThread       │
└──────┬────┘ └─────┬─────┘ └────┬─────┘ └────────┬────────┘
       │            │             │               │
┌──────▼────────────▼─────────────▼───────────────▼────────────────┐
│  Features              src/features                             │
│    App-facing API over platform backends                        │
│    FileSystem, Dialog, Shell, Database, HTTP, Store, ...         │
└───────────────────────────────┬────────────────────────────────┘
                                │
┌───────────────────────────────▼────────────────────────────────┐
│  Native integration    src/platform + standalone shards        │
│    CrystKit WebView/window backends + reusable OS services     │
└────────────────────────────────────────────────────────────────┘
```

The platform layer has no knowledge of IPC, plugins, or security. Features may use a narrow CrystKit platform backend or adapt a standalone shard, then add framework security and lifecycle behavior. Plugins depend on IPC, security, and features rather than platform internals. This lets the same application code run on all three operating systems without platform checks in domain logic.

## App As Composition Root

`App` wires the runtime together:

```text
CrystKit::App
  Runtime
    IPC::Router
    Security::Context
      CapabilitySystem        # global + per-window capability grants
      ScopeManager           # persisted filesystem scopes (mutex-guarded)
      Scopes::Loader         # in-memory resource scopes (HttpScope, ProcessScope, FsScope)
    Core::WindowRegistry
    Core::MainThread         # dispatch_sync onto the UI fiber
    Plugin::Registry
    Platform::Services       # CrystKit WebView/window integration
    Core::Lifecycle          # running? flag + shutdown hooks
  AppConfig
```

When you call methods such as `app.command`, `app.window`, `app.plugin`, `app.grant`, `app.emit`, or `app.run`, you are configuring or using services owned by the runtime.

That matters because desktop applications have shared state: open windows, native handles, event subscriptions, plugin cleanup, platform services, security grants, and shutdown order. CrystKit keeps those concerns behind one runtime instead of making each feature manage its own global state.

### Forward declarations

Several files (`src/ipc/command.cr`, `src/plugins/base.cr`) forward-declare `class App; end`, `module Core; class Window; end; end`, etc. to break the circular dependency between `App` and the subsystems that reference its types. Load order is managed by `src/crystkit.cr` — application code should never rely on a partial load; always `require "crystkit"` at the top of `main.cr`.

## App and Window Feature Ownership

Application-level native UI belongs to `App`; window-level native UI belongs to `Core::Window`. Normal application code should express intent through App, Window, labels, and target values instead of passing native handles.

For example, configure a menu bar through the app:

```crystal
app.menu_bar do |menu|
  menu.menu("File") do |file|
    file.item("Quit", "Cmd+Q") { app.quit }
  end
end
```

Or assign a prebuilt runtime menu:

```crystal
menu = CrystKit::Features::MenuBar.new
app.menu_bar = menu
```

CrystKit resolves the target window, applies the platform backend, and reuses the same binding when windows matching the target (by label or `:primary`) are created later. APIs that accept `Void*`, `Pointer(Void)`, `window.window`, or `native_handle(...)` are reserved for platform backends — application code should use the `App` and `Window` APIs instead.

The same ownership rule applies across native UI features:

| Scope       | Examples                                                                 | Public owner                                                                                         |
| ----------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| Application | Menu bar, system tray, global shortcuts, taskbar progress, notifications | `CrystKit::App`                                                                                      |
| Window      | Effects, DevTools, state persistence                                     | `CrystKit::Core::Window`                                                                             |
| Service     | Database, filesystem, HTTP, process, safe storage                        | Feature instance (e.g. `Features::FileSystem.new(app.security)`) or via a plugin's `Plugin::Context` |

## Runtime Services

### IPC Router

The router owns command registration, event subscriptions, channels, payload decoding, response envelopes, command policy, and frontend-originated authorization.

Crystal signatures define payload shape:

```crystal
app.command "greet", String do |name|
  "Hello, #{name}"
end

app.command "math.add", Int32, Int32 do |a, b|
  a + b
end
```

The frontend must match those shapes:

```js
await ipc.invoke("greet", "Crystal");
await ipc.invoke("math.add", [2, 3]);
```

Every payload crosses the boundary as `JSON::Any`. The router decodes incoming payloads into typed Crystal values via `IPC::Codec.decode`, and return values are coerced back to `JSON::Any` via `IPC::Codec.to_json_any` (which `App#coerce_to_json` delegates to). This single conversion point is why a handler can return a `String`, `Int32`, `Bytes`, `Enum`, or any `JSON::Serializable` struct and the frontend receives consistent JSON.

### Security Context

The security context owns capabilities, resource scopes, per-window grants, runtime prompts, violations, and in-memory resource scopes loaded from the manifest (`Scopes::HttpScope`, `Scopes::ProcessScope`, `Scopes::FsScope`).

Security is enforced for frontend-originated IPC calls only when the command has declared policy — a capability, a resource rule, or both. Commands without policy are public and run without checks. Backend Crystal code is trusted application code and can call its own functions directly.

There are three cooperating layers, checked in order:

1. **Capability** — coarse toggle (e.g. `fs:read`, `http:request`) granted globally or per-window. Absent ⇒ denied.
2. **Persisted scope** — filesystem path permission (`Read` / `Write` / `Execute`) stored in `ScopeManager` and persisted to disk. Paths are expanded via `Path#expand(home: true)` before matching, and `descendant_or_same?` resolves `..` lexically so traversal attempts (`/home/alice/Documents/../etc/passwd`) cannot escape a granted root.
3. **Resource scope** — in-memory prefix matcher for non-path resources (HTTP origins, process names). `FsScope` normalizes both the pattern and the resource; `HttpScope` rejects empty-host patterns like `https://`; `ProcessScope` rejects empty patterns that would silently match everything.

The `ScopeManager` is mutex-guarded because IPC handlers can run on different fibers. The same applies to `IPC::Channel#send`/`close`, the `EnhancedWindow` native-window map, and the `Store` plugin registry — concurrent mutation of Crystal's `Hash` is unsafe, so each shared container is wrapped in a `Mutex`.

### MainThread Dispatch

WebView and native-window operations must run on the application’s UI execution context, not on a background caller. `Core::MainThread` bridges CrystKit-owned window operations; the attached `native_desktop` runtime uses the same dispatcher for its GUI-bound services:

- `App#wire_window` captures the main fiber via `MainThread.capture_main_fiber` and registers a dispatcher proc (`MainThread.register`) when the first window is wired.
- `MainThread.dispatch_sync { ... }` from any fiber enqueues the block onto the UI fiber's run loop and blocks the caller until it returns. If the caller is already the main fiber, the block runs inline (no dispatch).
- The registration protocol uses a double-checked `@@dispatch` test inside the registration lock to avoid a TOCTOU where `register` clears the waiter list before a late caller appends to it.
- `dispatch_async` runs the block on the UI fiber without blocking the caller, returning a `CancellationToken` so the caller can cancel a slow operation.

Application code rarely calls `MainThread` directly. `Core::Window`, `EnhancedWindow`, and feature adapters dispatch internally. Plugin authors should use `Features::*` rather than touching `MainThread` or a platform FFI module.

### Window Registry

Windows are created through `app.window`. Each window is registered, wired to IPC, associated with a security context, and destroyed through runtime cleanup.

Labels make windows addressable:

```crystal
main = app.window(title: "Editor", label: "main")
settings = app.window(title: "Settings", label: "settings", visible: false)
```

The first registered window is the primary. The registry is documented as not fiber-safe — `App` ensures window create/destroy happen on the main fiber.

### Plugin Registry

Plugins expose native or application features through the same runtime model. The registry validates plugin identifiers, tracks command ownership, enforces dependency order, registers metadata, and cleans plugins up during shutdown.

Each plugin's `Metadata` declares its `IPC::PolicyCatalog`, capabilities, commands, and events. The registry validates that every IPC policy command appears in the declared command list, auto-grants the plugin's declared capabilities (a "demo mode" convenience — see [Security](security.md) for why a real app should load a `capabilities.json` manifest instead), cross-checks the commands actually registered in `initialize_plugin` against the declared list, and tears the plugin down on mismatch.

### Platform Services

`Platform::Services` contains only backends coupled to CrystKit’s WebView host: window creation, window integration, drag/drop reception, WebView printing, and the custom asset protocol. Compile-time aliases select the matching implementation.

Reusable operating-system controls are owned by standalone shards. CrystKit feature adapters call [native_desktop](https://github.com/naqvis/native_desktop), [safe_storage](https://github.com/naqvis/safe_storage), [system_info](https://github.com/naqvis/system_info), and [file_watcher](https://github.com/naqvis/file_watcher), then add capabilities, IPC models, event forwarding, and app lifecycle. This avoids maintaining a second FFI implementation inside CrystKit.

The FFI that remains under `src/platform/<os>/` supports CrystKit-specific integration such as WebView dispatch, DevTools, custom protocols, enhanced windows, printing, and NSPanel. Application and plugin code never imports it directly.

### Lifecycle

The lifecycle service coordinates startup, readiness, shutdown hooks, plugin cleanup, and window destruction. `app.run` starts the primary window's event loop and blocks until it closes. It raises `Core::Error` if no window has been created. The `ensure` block in `run` runs `shutdown` and rescues its exceptions so a failure during teardown does not swallow the original error from `window.run`.

Each shutdown step is wrapped in a `quietly(label) { ... }` helper so a failure in one phase (e.g. tray destroy) is logged and doesn't prevent the remaining phases (plugins, lifecycle hooks, windows, MainThread clear) from running.

## Request Lifecycle

A frontend call such as:

```js
await ipc.invoke("fs.read_text", { path: "/tmp/a.txt" });
```

flows through the runtime:

```text
Frontend JavaScript
  ipc.invoke("fs.read_text", {path})
        |
        v
Injected JS bridge
  serializes the command and payload
        |
        v
IPC::Router
  checks payload size
  finds the command
  decodes the payload
        |
        v
Policy resolution
  app config override
  plugin metadata
  public fallback
        |
        v
Security context
  checks capability grants
  checks window restrictions
  checks resource scopes
        |
        v
Command handler
  performs the native or app operation
        |
        v
Response envelope
  resolves or rejects the frontend promise
```

The key idea is that IPC, security, and plugins are not separate stories. A plugin command usually declares policy in plugin metadata. The router resolves that policy when the frontend invokes the command. The security context checks whether the invoking window has the required authority and resource access. Only then does the handler run.

### Async commands and channels

A command declared with `app.async` returns immediately with an async sequence id; the handler runs in a spawned fiber bounded by an optional timeout (enforced via `select` on a timeout channel). The result is delivered back to the frontend through the same `ResponseEnvelope` shape.

`IPC::Channel(T)` provides ordered streaming from Crystal to JS after a command has returned. `send` / `close` / `close_with_error` are mutex-guarded so a concurrent `close` cannot interleave with a `send` and emit data after the close event. Each `send` emits a `__channel_data:<id>` event carrying a monotonic `seq`; the frontend uses `seq` to detect gaps.

### Events

Backend → frontend events use `app.emit(name, payload, target: ...)`. The router's `emit_event` validates that `name` is a declared frontend-emittable event, then iterates subscribers with a per-subscriber rescue so one failing listener doesn't break the rest. A `target` (label, `:primary`, `:all`, or a specific `Window`) restricts which windows receive the event.

## Configuration Boundaries

CrystKit has two configuration layers because build-time and runtime concerns are different.

### `crystkit.json`

`crystkit.json` is builder configuration. It tells the CLI how to develop, build, bundle, generate schemas, locate frontend assets, and package the app.

It can carry window definitions (title, size, label, URL, decorations, fullscreen, transparency, etc.) as build and packaging metadata, but it does not automatically create runtime windows. Your Crystal code still calls `app.window`.

`@[JSON::Field]` constraints (minimum, maximum, pattern, etc.) on the config model are metadata for schema generation and are **not** automatically enforced at parse time — `Config#validate!` re-checks the important ones (identifier format, name non-empty, window sizes ≥ 100). A config that passes `JSON.parse` but violates an annotation will still load unless `validate!` catches it.

### `AppConfig`

`AppConfig` is runtime configuration. It contains values the running app needs: name, version, identifier, storage directory, capability manifest path, CSP, and protocols.

Builder config can be converted into runtime config:

```crystal
require "crystkit/build/config"

builder = CrystKit::Builder::Config.load("crystkit.json")
app = CrystKit::App.new(builder.to_app_config)
```

Only runtime-relevant fields map across. Build commands, bundle targets, and static window definitions remain builder concerns.

### `capabilities.json`

`capabilities.json` is the app's authority manifest. It declares app-owned capabilities, groups, per-window restrictions, and resource scopes. It is not a list of plugin commands. Plugin metadata maps plugin commands to capabilities.

Loading the manifest via `app.security.load_manifest(path)` auto-grants the declared capabilities, applies per-window allow-lists, and mirrors declared `fs` scope paths into the persisted `ScopeManager` (with `Write` permission if any `fs:write`/`fs:delete` capability is declared, else `Read`). A manifest entry of `"*"` for `fs` scopes is expanded to `Path["/"]` and logged at warn level — it is a blanket filesystem grant and should be used deliberately.

## Windows And Security

Every window has an identity in the runtime. That identity matters for IPC and security.

```crystal
app.window(title: "Main", label: "main")
app.window(title: "Preview", label: "preview")
```

When a frontend invokes a privileged command and per-window restrictions are configured, CrystKit checks both global app authority and the invoking window's authority. Unlisted windows receive no privileged grants. This lets a main editor window save files while a preview window remains read-only.

Child windows inherit capabilities from their parent through `app.capabilities.set_window_parent("child_label", "parent_label")`. Inheritance is transitive — the child's effective set is the union of its own grants and every ancestor's. Cycle detection prevents infinite loops.

## Plugins And Native Features

Native features are usually exposed through plugins. A plugin can:

- register commands,
- subscribe to events,
- declare metadata,
- declare command policy,
- receive plugin-specific configuration,
- react when windows are created,
- clean up during shutdown.

This is how CrystKit keeps native functionality consistent. The same command, metadata, security, lifecycle, and cleanup model applies whether the plugin is built in or written by your application.

Plugins receive a `Plugin::Context` in `initialize_plugin` that exposes `app`, `router`, `security`, and `config`. The `security` field is a `Security::Context` bound to the app — use `context.security.require_path!` to enforce persisted scopes in handlers that touch the filesystem, or `context.security.scopes.require!` for direct scope enforcement. Plugins that only need capability checks may use `context.capabilities` instead; plugins that need resource scopes (HTTP origins, process names) should thread `context.security` so the scope layer is consulted.

A canonical builtin plugin (`Plugins::FS`) shows the pattern: declare `metadata` with an `IPC::PolicyCatalog` that binds each command to its capability and resource rule, register commands in `initialize_plugin`, and define `cleanup_plugin` to release any handles. See [Plugins](plugins.md) for the full authoring guide.

## Error Model

All non-stdlib errors raised by CrystKit subclass `Core::Error`, which carries a stable machine-readable `code` (`String?`) and a `context` hash. Subtypes:

- `Core::IPCError` — boundary failures with codes like `COMMAND_NOT_FOUND`, `IPC_POLICY_MISSING`, `CHANNEL_CLOSED`, `DECODE_ERROR`.
- `Core::PluginError` — registration / metadata failures.
- `Core::SecurityError` — `CAPABILITY_DENIED`, `SCOPE_DENIED`, `INVALID_PATH`, `PATH_TRAVERSAL`, `MANIFEST_NOT_FOUND`.
- `Core::FileSystemError`, `Core::NetworkError`, `Core::TimeoutError`, `Core::ValidationError`, `Core::CancelledError`.

The router wraps any unhandled exception from a command handler into a `ResponseEnvelope.failure` with a stable code, so the frontend always receives a structured response rather than a bare crash. Plugin `cleanup_plugin` failures are logged and swallowed so one failing cleanup doesn't block the rest of shutdown.

Bare `rescue` blocks are avoided in production code — rescues name a specific exception type and log via `Log.warn(exception: ex) { ... }`.

## Concurrency Model

CrystKit runs on Crystal's execution-context scheduler. The webview's UI event loop owns the "main fiber" on the default execution context (parallelism 1); all native window mutations must execute on it. Code that needs to call a native API from a background fiber (e.g. an async IPC handler) does so via `MainThread.dispatch_sync` / `dispatch_async`.

Background work (IPC handlers, monitors, servers, watchers) spawns into a separate `Parallel` execution context owned by `Core::Fibers`, so background fibers never get scheduled onto the main thread and the GUI loop never starves. Fibers are tied to their context — the main fiber's context has no other schedulers, so background work physically cannot land on the main thread.

Shared mutable state that can be touched by multiple fibers is mutex-guarded. The notable mutex-protected containers are:

- `IPC::Channel` — `send` / `close` / `close_with_error` are atomic.
- `Security::ScopeManager` — all mutating and read operations.
- `EnhancedWindow.@@native_window_map` — window registration and lookup.
- `Plugins::Store.@stores` — the per-name store registry.

Under the `Parallel` execution context these mutexes are essential: fibers run on multiple OS threads simultaneously, so unsynchronized access to shared state is a real data race, not just a theoretical concern.

## Shutdown

When the primary window closes or `app.shutdown` is called, CrystKit tears the runtime down in an ordered way:

1. Global shortcuts stop listening; the system tray is destroyed.
2. Plugin cleanup runs in reverse registration order.
3. Lifecycle shutdown hooks run (reverse registration order, exceptions logged and swallowed).
4. Open windows are destroyed.
5. The main-thread dispatch queue is cleared.

Each step is wrapped in `Runtime#quietly(label) { ... }`, which rescues and logs via `Log.error(exception: ex)` so a failure in one phase cannot skip the remaining phases. `App#run` wraps the whole `shutdown` call in its own rescue so a teardown error doesn't replace the original exception from `window.run`.

Your app should put cleanup behavior in lifecycle hooks or plugin cleanup methods instead of relying on individual windows to clean up unrelated systems.

## Next

Run `crystkit --help` and the relevant subcommand’s `--help` for project setup, development, build, and packaging options.

Then use the focused guides:

- [IPC](ipc.md) for commands, events, channels, errors, and type generation.
- [Security](security.md) for capabilities, scopes, manifests, windows, prompts, and CSP.
- [Plugins](plugins.md) for built-in features and custom plugin authoring.
- [Windows](windows.md) for window lifecycle, labels, parent-child relationships, and multi-window design.
