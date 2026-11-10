# Security

CrystKit gives desktop applications native power, so it also gives that power a runtime authority model. File access, HTTP requests, shell execution, dialogs, clipboard, notifications, printing, and similar operations should be explicit: the app grants authority, commands declare what they need, and resource scopes limit what that authority can touch.

Read [IPC](ipc.md) first if the frontend command path is not clear yet.

## The Model

Security has four connected pieces:

| Piece               | Responsibility                                                      |
| ------------------- | ------------------------------------------------------------------- |
| Plugin metadata     | Maps plugin commands to required capabilities and resources.        |
| App grants          | Declare which capabilities the application owns.                    |
| Resource scopes     | Restrict capabilities to paths, URLs, commands, or other resources. |
| Window restrictions | Limit which windows may use privileged frontend IPC.                |

Those pieces meet when the frontend invokes a privileged command.

Example:

```js
await ipc.invoke("fs.read_text", { path: "/Users/alice/Documents/note.md" });
```

For that command to run:

1. The FS plugin metadata must say that `fs.read_text` requires `fs:read` and a readable `path`.
2. The app must grant `fs:read`.
3. The path must match an allowed filesystem scope.
4. If the app uses per-window restrictions, the invoking window must be allowed to use `fs:read`.

Only then does the command handler execute.

## What Security Protects

Frontend code is treated as less trusted than backend Crystal code. The frontend can request work through IPC, but privileged native work is authorized before the handler runs.

Backend Crystal code is application code. It can call its own methods and services directly. Capability enforcement is primarily for frontend-originated IPC and native feature surfaces exposed to the frontend. However, backend code can also opt into the same enforcement — see [Backend enforcement](#backend-enforcement).

## What the Framework Secures vs. What's Your Responsibility

This is the single most important thing to understand about CrystKit's security model, because the boundary is **by surface, not by caller**.

**The framework owns security for native OS interactions.** Every built-in plugin and feature that touches the operating system — filesystem, dialogs, clipboard, shell, process, HTTP, notifications, printing, and the rest — is gated by capabilities and scopes *before* the handler runs, and that check happens at the IPC boundary automatically. You register the plugin, the framework enforces the contract. You should never have to hand-write a permission check to use a native feature safely from the frontend.

**Your own backend commands (`app.command` / `app.async`) are public by default, and that is intentional.** These are *your* Crystal logic. When the frontend invokes one, the router resolves no policy for it and treats it as public — no capability or scope check is applied. This is a deliberate design choice, not a gap:

- The contract exists to protect **native OS access**, which the framework provides. Your application code is already trusted backend code; making you annotate every `app.command` with a capability, scope, and resource type would bloat every backend function with framework ceremony it didn't ask for.
- If *you* choose to wrap a native OS call inside an `app.command` (e.g. a custom `fs.delete_everything` command) and expose it to the frontend, **gating it is your responsibility** — the same as if you had called that native API directly from Crystal. The framework does not second-guess what your own function should be allowed to do.

So the rule is simple:

| Surface                                  | Enforcement                                  | Who is responsible |
| ---------------------------------------- | -------------------------------------------- | ------------------- |
| Built-in plugin commands (e.g. `fs.*`)   | Automatic at the IPC boundary               | Framework           |
| Built-in features called from Crystal    | Automatic when you pass `app.security`       | Framework (opt-in)  |
| Your `app.command` / `app.async`         | None — public by default                     | You                 |
| Your `app.command` that wraps native OS  | None unless you opt in (below)               | You                 |

**Opting your app commands into enforcement.** When a backend command *does* expose something sensitive to the frontend and you want the framework to enforce it, declare a policy in `crystkit.json` — see [Plugin Metadata And App Grants](#plugin-metadata-and-app-grants) for the `app.ipc.commands` override form. Overrides win over plugin policies, so you can tighten any command, including your own. From Crystal you can also enforce directly with `app.capabilities.require!` or `app.security.require_path!` / `require_resource!` (see [Backend enforcement](#backend-enforcement)).

Keep public app commands genuinely harmless. A command that only computes, formats, or returns backend state needs no policy. A command that deletes files, spawns processes, or opens sockets should either be scoped to a backend-only path or carry an explicit policy.

## Capabilities

A capability is a string in `<area>:<action>` form:

```text
fs:read
fs:write
dialog:open
http:request
shell:execute
clipboard:write
notification:show
```

Capability identifiers are matched as **exact strings**. Unlike scope patterns (which support wildcards), there is no prefix or glob expansion for capabilities. `clipboard:*` does not grant `clipboard:read`; only the literal string `"clipboard:read"` matches.

Common capabilities:

| Area                  | Capabilities                                                                                                                                      |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Filesystem            | `fs:read`, `fs:write`, `fs:delete`                                                                                                                |
| HTTP                  | `http:request`                                                                                                                                    |
| Process               | `process:spawn`, `process:kill`                                                                                                                   |
| Shell                 | `shell:execute`                                                                                                                                   |
| Dialog                | `dialog:open`, `dialog:save`                                                                                                                      |
| Clipboard             | `clipboard:read`, `clipboard:write`                                                                                                               |
| Notifications         | `notification:show`                                                                                                                               |
| Printing              | `printing:print`, `printing:pdf`, `printing:info`                                                                                                 |
| Other native features | `websocket:connect`, `external:open`, `hardware:list`, `hardware:manage`, `sidecar:execute`, `speech:synth`, `speech:recognize`, `window:effects` |

Grant capabilities in code for small apps:

```crystal
app.grant("dialog:open", "fs:read")
```

For real applications, prefer a manifest so the app's authority is visible and reviewable.

### Plugin capabilities: with and without a manifest

When you register a plugin, it **declares** its capabilities via metadata. Whether those capabilities are auto-granted depends on whether a manifest is loaded:

| | Manifest loaded | Plugin auto-grant | Developer control |
| --- | --- | --- | --- |
| No manifest | No | Yes — `app.plugin(FS.new)` grants `fs:read`, `fs:write`, `fs:delete` automatically | None needed; `app.grant(...)` is for caps no plugin provides |
| With manifest | Yes | No — plugin declares but does **not** grant | Manifest `capabilities` + `app.grant(...)` are the sole source of authority |

Without a manifest, registering the FS plugin gives you all three fs capabilities. This is convenient for single-file scripts and quick prototypes.

With a manifest, registering the FS plugin only declares that its commands need `fs:read`/`fs:write`/`fs:delete`. The app must explicitly grant them via the manifest or `app.grant(...)`. This lets you register the FS plugin but allow only `fs:read` — `fs.write_text` will be denied even though the plugin is registered.

```crystal
# No manifest: plugin auto-grants
app.plugin CrystKit::Plugins::FS.new   # fs:read, fs:write, fs:delete all granted

# With manifest: only listed caps are granted
config = CrystKit::AppConfig.new(
  capabilities_manifest: Path["capabilities.json"],
  # capabilities.json lists only "fs:read"
)
app = CrystKit::App.new(config)
app.plugin CrystKit::Plugins::FS.new   # declares fs:read/fs:write/fs:delete
# fs.write_text → CAPABILITY_DENIED (fs:write not granted)
```

## Capability Manifest

Load a manifest through `AppConfig`:

```crystal
config = CrystKit::AppConfig.new(
  name: "Notes",
  identifier: "com.example.notes",
  capabilities_manifest: Path["capabilities.json"],
)

app = CrystKit::App.new(config)
```

Example `capabilities.json`:

```json
{
  "$schema": "./schemas/capabilities.schema.json",
  "capabilities": ["fs:write", "dialog:open"],
  "groups": {
    "file-editor": ["fs:write", "dialog:open", "dialog:save"]
  },
  "windows": {
    "main": ["fs:read", "fs:write", "dialog:open", "dialog:save"],
    "preview": ["fs:read"]
  },
  "scopes": {
    "fs": ["~/Documents"]
  }
}
```

Fields:

| Field          | Purpose                                                                                                                               |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `capabilities` | App-owned global capabilities. With a manifest, these (plus explicit `app.grant` calls) are the sole source of authority — plugin capabilities are declared but not auto-granted. Without a manifest, plugins auto-grant their own caps, so this field only adds caps no plugin provides. |
| `groups`       | Named capability sets for organization. No runtime enforcement — authoring convenience.                                               |
| `windows`      | Per-window allow-lists. If present, privileged frontend IPC must pass the invoking window's allow-list.                               |
| `scopes`       | Resource patterns by area. How each area is enforced depends on the scope type — see [The two scope systems](#the-two-scope-systems). |

The manifest is not a plugin command registry. Plugin commands and their required capabilities are declared by plugin metadata.

## Plugin Metadata And App Grants

Plugin metadata answers: "What does this command require?"

```crystal
def metadata
  ipc = CrystKit::IPC::PolicyCatalog.new
    .path("fs.read_text", "fs:read", "path", IPC::ResourcePermission::Read)
    .path("fs.write_text", "fs:write", "path", IPC::ResourcePermission::Write)

  Metadata.new(
    id: "fs",
    capabilities: ["fs:read", "fs:write", "fs:delete"],
    commands: %w(fs.read_text fs.write_text fs.exists fs.remove_file),
    ipc: ipc,
  )
end
```

The app manifest answers: "Which of these powers does this application allow, and where?"

```json
{
  "capabilities": ["fs:write"],
  "scopes": {
    "fs": ["~/Documents"]
  }
}
```

With a manifest, the manifest is the sole source of authority. Registering the FS plugin declares `fs:read`, `fs:write`, `fs:delete` but grants none of them. The manifest must list the ones the app needs — e.g. only `fs:write` here means `fs.read_text` will be denied. Without a manifest, the plugin auto-grants all three.

This separation avoids duplicating command policy in application config.

Application commands can also opt into pre-handler enforcement through `crystkit.json`:

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

Use this for privileged app commands. Do not use command names as implicit capabilities; CrystKit does not infer policy from names.

## Enforcement Flow

For frontend-originated IPC, the router (`src/ipc/router.cr`) runs this check on every `ipc.invoke` call:

```text
ipc.invoke(name, params)
  |
  v
policy = resolver.resolve(name)
  |
  +-- policy.capability nil AND policy.resources empty?
  |     YES → public; skip all checks
  |
  +-- policy.capability set?
  |     security.require!(capability, context: "ipc:<name>")
  |     (global grant + per-window check, records violation on denial)
  |
  +-- for each ResourceRule:
  |     resource = extract(params, rule.json_path)
  |
  |     case rule.kind:
  |       Path  → security.require_path!(cap, Path[resource], permission)
  |                (capability check + persisted path scope)
  |       Resource → security.require_resource!(cap, resource)
  |                (capability check + in-memory scope for prefix)
  |
  v
Command handler (only reached when all checks pass)
```

Key details:

- `resolve` checks app overrides first, then plugin metadata, then `CommandPolicy.public` (no security). Overrides win over plugins.
- `require!` on `Security::Context` delegates to `CapabilitySystem#require!`, which checks global grants and, when per-window restrictions exist, the invoking window's effective capability set (own grants + ancestor chain).
- `require_path!` runs the capability check _and_ a persisted path scope check (`src/security/scope.cr` — prefix match, longest prefix wins).
- `require_resource!` runs the capability check _and_ an in-memory scope check (`src/security/scopes/` — `HttpScope`, `ProcessScope`, etc.).
- If no policy resolves for a command, it is public (no checks).

## The Two Scope Systems

Capabilities say **what** kind of action is allowed. Scopes say **where** that action is allowed. But there are two distinct scope systems that work differently depending on what kind of resource is being protected.

### 1. Persisted path scopes (filesystem)

Gate filesystem paths like files, directories, and device files. Managed by `ScopeManager` (`src/security/scope.cr`). Persisted to disk at `<storage_dir>/scopes.json`. Three permission levels:

| Permission | Semantics |
| --- | --- |
| `Read` | Path may be opened for reading. |
| `Write` | Path may be opened for writing. Implies `Read`. |
| `Execute` | Path may be executed as a program. |

Matching is **prefix-based**: a request for `/home/alice/docs/x.txt` is satisfied by any non-expired scope whose path is a prefix of the target (e.g. `/home/alice/docs` or `/home/alice`). A `Write` scope satisfies both `Write` and `Read` requests. There is no preference for the longest prefix. This is used by every `fs.*` IPC command that declares a `path`-kind `ResourceRule`.

Convenience patterns — `"*"` and `"~"` are resolved to real paths:

```json
{
  "scopes": {
    "fs": ["*"]
  }
}
```

`"*"` matches every path (resolves to root `"/"`). `"~"` resolves to the user's home directory. In code, `persist` accepts both patterns and raw paths:

```crystal
app.scopes.persist("*", Permission::Write)     # → root "/"
app.scopes.persist("/", Permission::Write)      # explicit root
app.scopes.persist("~", Permission::Read)       # → home dir
app.scopes.persist(Path.home, Permission::Read)  # explicit home
```

Set from the manifest:

```json
{
  "scopes": {
    "fs": ["~/Documents", "/tmp/my-app"]
  }
}
```

Set from code (no manifest needed — useful for demos):

```crystal
app.scopes.persist(Path.home / "Documents", CrystKit::Security::Permission::Write)
app.scopes.persist("/tmp/my-app", CrystKit::Security::Permission::Read)   # String works too
```

`~` is expanded to the user's home directory. Scopes can carry an expiry:

```crystal
app.scopes.persist("/tmp/session", CrystKit::Security::Permission::Write,
  expires_at: Time.utc + 1.hour)
```

### 2. In-memory resource scopes (HTTP, process, shell)

Gate non-filesystem resources like URLs, process names, and shell commands. Managed by `Scopes::BaseScope` subtypes (`src/security/scopes/`). Loaded from the manifest `scopes` section at startup; **not persisted** to disk (they reload from the manifest on every launch).

Set from the manifest:

```json
{
  "scopes": {
    "http": ["https://api.example.com/*", "https://trusted.example.com"],
    "process": ["git", "node"],
    "shell": ["open"]
  }
}
```

Set from code (no manifest needed):

```crystal
app.security.resource_scopes["http"] = CrystKit::Security::Scopes::HttpScope.new([
  "https://api.example.com/*",
])
app.security.resource_scopes["process"] = CrystKit::Security::Scopes::ProcessScope.new([
  "git", "node",
])
app.security.resource_scopes["shell"] = CrystKit::Security::Scopes::ProcessScope.new([
  "open",
])
```

Pattern matching rules by scope type:

| Type           | Matching                                                                                                                                               | Validation |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------- |
| `FsScope`      | String-prefix against expanded path. `"*"` expands to root `"/"` (all paths). `"~"` expands to home. Both the pattern **and** the resource are normalized via `Path#expand(home: true)` + `Path#normalize` before matching, so traversal sequences (`..`) in the resource cannot escape a granted root (e.g. `/home/alice/Documents/../etc/passwd` is resolved to `/etc/passwd` which is not a descendant of `/home/alice/Documents`). | Empty patterns rejected at construction. |
| `HttpScope`    | Exact match, trailing-wildcard (`https://api.example.com/*`), or trailing-slash (`https://api.example.com/`). Special pattern `"*"` allows any origin. | Patterns must include a non-empty host after stripping scheme + trailing `*`/`/`. `"https://"` and `"https://*"` are rejected — they would otherwise approve every URL of that scheme. |
| `ProcessScope` | String-prefix. `"git"` matches both `"git"` and `"git status"`. Special pattern `"*"` allows any command.                                              | Empty patterns rejected at construction — an empty prefix matches every resource and would silently grant the universe. |

### Concurrency and persistence safety

`ScopeManager` is mutex-guarded so concurrent IPC handlers running on different fibers cannot race the in-memory `@scopes` hash or corrupt the on-disk `scopes.json`. Every mutating call (`persist`, `revoke`, `clear`, `cleanup_invalid`) and every read (`validate`, `has_scope?`, `query`) acquires the lock for the full operation, including the disk write. This matters under the `Parallel` execution context and any time multiple IPC fibers reach the security layer simultaneously.

`validate_path!` expands the path with `Path#expand(home: true)` (which lexically resolves `..`) and rejects any expanded path that still contains `..` — that signals a non-normalizable traversal attempt. This is a defense-in-depth check on the *persisted* side; the in-memory `FsScope` also normalizes the resource at lookup time, so a malicious payload that passes `validate_path!` is still contained by the prefix match.

### The bridge: how manifest `scopes.fs` becomes a persisted scope

When you load a capabilities manifest, `Context#load_manifest` (`src/security/context.cr:135-148`) does two things with the `scopes.fs` section:

1. Creates an `FsScope` for the in-memory prefix check (`require_resource!`).
2. Mirrors every path into the persisted `ScopeManager` so `require_path!` (used by `fs.*` commands written to `path`-kind rules) works too.

If the manifest declares `fs:write` or `fs:delete`, the persisted scopes are created with `Permission::Write`; otherwise with `Permission::Read`.

This mirroring means a filesystem path only needs to be listed once in the manifest — it becomes usable by both the in-memory and the persisted scope path. When you set scopes from code, you must call `app.scopes.persist(...)` directly (the mirroring only runs during manifest load).

## Config vs Code: manifest field reference

Every manifest field has an equivalent code API, useful when building single-file demos or when the manifest's structure doesn't match your design.

| Manifest field                    | Equivalent in code                                                  |
| --------------------------------- | ------------------------------------------------------------------- |
| `capabilities`                    | `app.grant("fs:read", "dialog:open")`                               |
| `scopes.fs`                       | `app.scopes.persist(path, Permission::Read/Write/Execute)`          |
| `scopes.http`                     | `app.security.resource_scopes["http"] = HttpScope.new([...])`       |
| `scopes.process` / `scopes.shell` | `app.security.resource_scopes["process"] = ProcessScope.new([...])` |
| `windows`                         | `app.capabilities.grant_to_window("fs:read", "main")`               |
| `groups`                          | No runtime equivalent (authoring convenience only)                  |

Complete single-file demo (no manifest, no `crystkit.json`):

```crystal
require "crystkit"
require "crystkit/plugins/builtins"

CrystKit::App.run do |app|
  app
    .grant("dialog:open", "dialog:save")
    .plugin(CrystKit::Plugins::Dialog.new)
    .plugin(CrystKit::Plugins::FS.new)    # auto-grants fs:read, fs:write, fs:delete

  app.scopes.persist(Path.home / "Documents", CrystKit::Security::Permission::Write)

  app.security.resource_scopes["http"] = CrystKit::Security::Scopes::HttpScope.new([
    "https://api.example.com/*",
  ])

  app.command "fs.read_text", String do |params|
    # ...
  end

  app.window(title: "Demo", label: "main")
end
```

## Per-Window Authority

Windows can have different authority. This matters for apps with settings, preview, authentication, or helper windows.

Define them in the manifest:

```json
{
  "windows": {
    "main": ["fs:read", "fs:write"],
    "preview": ["fs:read"],
    "settings": []
  }
}
```

Create windows with matching labels:

```crystal
app.window(title: "Notes", label: "main")
app.window(title: "Preview", label: "preview")
```

When any manifest window allow-list exists, privileged frontend IPC must be allowed by the invoking window. Unlisted windows receive no privileged frontend IPC grants.

### Full code API (no manifest)

```crystal
# Grant capabilities to specific windows
app.capabilities.grant_to_window("dialog:open", "main")
app.capabilities.revoke_from_window("fs:delete", "main")

# Read current grants
caps = app.capabilities.window_capabilities("main")
effective = app.capabilities.effective_capabilities_for_window("main")
restricted = app.capabilities.window_restrictions?

# Parent-child inheritance
app.capabilities.set_window_parent("preview", "main")
parent = app.capabilities.window_parent("preview")   # => "main"
app.capabilities.unset_window_parent("preview")

# Temporary window grants
app.capabilities.grant_temporary_to_window("clipboard:read", "main", 30.seconds)
```

### Inheritance

Child windows inherit all capabilities from their parent window, transitively. The effective capability set for any window is the union of its own grants and every ancestor's grants. Cycle detection prevents infinite inheritance loops.

```crystal
app.capabilities.set_window_parent("settings", "main")
app.capabilities.set_window_parent("nested", "settings")
# nested inherits main + settings + nested
```

## Runtime Requests

Applications can request authority at runtime instead of pre-granting it.

### Simple prompt

```crystal
app.capabilities.set_prompt_handler do |capability|
  puts "Allow #{capability}? y/n"
  gets.try(&.chomp) == "y"
end

if app.capabilities.request_capability("clipboard:read", reason: "Paste note")
  # perform operation
end
```

### Full request handler with reason and expiry

```crystal
app.capabilities.on_capability_request do |request|
  puts "App needs #{request.capability}"
  puts "  Reason: #{request.reason}" if request.reason
  puts "  Expires: #{request.expires_at}" if request.expires_at

  if request.capability.starts_with?("clipboard:")
    CapabilityRequestOutcome::Approved
  else
    CapabilityRequestOutcome::Denied
  end
end
```

### Async prompt UI (out-of-band approval)

For prompts that cannot block (e.g., a frontend dialog), capture the request inside the `on_capability_request` handler and answer it from another fiber:

```crystal
app.capabilities.on_capability_request do |request|
  # Store the request id for later approval
  pending_request_id = request.id

  # Forward to UI, return a placeholder outcome
  CapabilityRequestOutcome::Denied
end
```

Note: `request_capability` removes the request from `pending_requests` synchronously after the handler returns, so `approve_request`/`deny_request` must be called *during* the handler invocation (e.g. from a spawned fiber that later resolves the answer). The synchronous handler return value is what `request_capability` reports to the caller.

If no prompt handler is registered, runtime requests are denied by default (secure default). Use runtime requests for user-initiated actions. Do not use them as a substitute for a well-scoped manifest.

## Temporary and Scoped Grants

Beyond the simple `app.grant("cap")`, individual grants can carry scope prefixes and expiries.

### Temporary grants

```crystal
app.capabilities.grant_temporary("clipboard:read", 5.minutes)
# expires in 5 minutes, auto-revoked by `check` / `require!`
```

### Scoped grants

A grant can be narrowed with a resource prefix. The grant only authorizes resources that start with that prefix:

```crystal
# Only allows fs:read for paths under ~/Downloads
app.capabilities.grant("fs:read", scope: Path.home.to_s + "/Downloads",
  expires_at: Time.utc + 1.hour)
```

This is distinct from the manifest `scopes` map — it's a per-grant narrowing.

## Backend Enforcement

Backend Crystal code can also participate in the security model, even when not triggered by frontend IPC. This is useful for defense-in-depth when a command handler touches sensitive resources.

### Direct capability and scope checks

```crystal
# Non-raising check
if app.capabilities.check("fs:write", resource: path.to_s)
  # perform fs:write operation
end

if app.capabilities.check_for_window("fs:write", "main", resource: path.to_s)
  # check with per-window restrictions
end

# Raising variants for guard-clause style
app.capabilities.require!("fs:write", resource: path.to_s,
  context: "my_command")
app.capabilities.require_for_window!("fs:write", "main",
  resource: path.to_s, context: "window:main")
```

### Security context methods

The `Security::Context` offers combined checks:

```crystal
ctx = app.security

# Capability + persisted path scope
ctx.require_path!("fs:write", Path["~/Documents/notes.txt"], Permission::Write)

# Capability + in-memory resource scope
ctx.require_resource!("http:request", "https://api.example.com/users")
```

### Built-in features accept a security context

Several built-in feature classes accept `app.security` (or `app.capabilities`) to enforce policy without frontend IPC:

```crystal
require "crystkit/features/..."

fs = CrystKit::Features::FileSystem.new(app.security)
dialog = CrystKit::Features::FileDialog.new(app.security)
http = CrystKit::Features::HTTPClient.new(app.security)
manager = CrystKit::Features::ProcessManager.new(app.security)
executor = CrystKit::Features::ShellExecutor.new(app.security)
client = CrystKit::Features::WebSocketClient.new(app.capabilities)
```

Each feature checks the required capabilities and scopes before delegating to the native platform. This means even if you call `fs.read_text` from Crystal code (not frontend IPC), the enforcement still runs.

## Persistent Scopes

The scope manager persists path permissions across restarts:

```crystal
path = Path["/Users/alice/Documents/notes"]

app.scopes.persist(path, CrystKit::Security::Permission::Read)
app.scopes.persist(
  path,
  CrystKit::Security::Permission::Write,
  expires_at: Time.utc + 1.day,
)

app.scopes.require!(path, CrystKit::Security::Permission::Read)
```

Persisted scopes are stored under `<storage_dir>/scopes.json`, checked for expiry, and validated against path traversal on write.

Additional `ScopeManager` APIs:

```crystal
app.scopes.validate(path, Permission::Read)   # non-raising bool
app.scopes.has_scope?(path)                    # bool, any permission
app.scopes.revoke(path)                        # remove
app.scopes.query                               # all non-expired
app.scopes.cleanup_invalid                     # prune expired
```

## Content Security Policy

`AppConfig#csp` is injected into app-created windows as a `<meta http-equiv="Content-Security-Policy">` tag in the document `<head>`:

```crystal
config = CrystKit::AppConfig.new(
  name: "My App",
  csp: "default-src 'self'; connect-src https://api.example.com"
)
```

The injection is handled by `App#inject_csp` (`src/app/app.cr:368-382`), which appends the meta tag to every window the app creates. CSP set this way only affects the HTML content — native JavaScript injected by the bridge is not subject to the CSP.

### Builder config vs runtime config

`crystkit.json` has an `app.security` section with runtime and builder fields. `Builder::Config#to_app_config` maps runtime fields into `AppConfig`; builder fields remain part of the project configuration.

**Fields that reach the runtime (on `AppConfig`):**

| Field                   | Purpose                                                                                           |
| ----------------------- | ------------------------------------------------------------------------------------------------- |
| `capabilities_manifest` | Path to `capabilities.json`. Read by `App#load_capabilities_manifest` (`src/app/app.cr:296-302`). |
| `csp`                   | Content Security Policy. Injected as `<meta>` in app-created windows.                             |

These are the only two fields mapped by `Builder::Config#to_app_config` (`src/builder/config.cr:672-688`).

**Builder security fields:**

| Field                                      | Purpose                          | Runtime mapping          |
| ------------------------------------------ | -------------------------------- | ------------------------ |
| `dev_csp`                                  | CSP used during development      | Not mapped to `AppConfig` |
| `allow_cors`                               | Allow CORS from webview content  | Not mapped to `AppConfig` |
| `isolation`                                | Enable webview process isolation | Not mapped to `AppConfig` |
| `isolation_allowlist`                      | URLs allowed in isolated context | Not mapped to `AppConfig` |
| `freeze_prototype`                         | Freeze JS built-in prototypes    | Not mapped to `AppConfig` |
| `asset_protocol`                           | Allow/deny globs for asset URLs  | Not mapped to `AppConfig` |
| `dangerous_disable_asset_csp_modification` | Disable CSP modification         | Not mapped to `AppConfig` |

These fields are defined in `Builder::SecurityConfig` (`src/builder/config.cr:322-364`) and participate in `crystkit.json` schema validation. They do not affect runtime application behavior.

## Audit Trail

Denied capability access is recorded as a violation:

```crystal
app.capabilities.violations.each do |violation|
  puts "#{violation.timestamp}: #{violation.capability}" \
       " (#{violation.context || "no context"})"
end
```

CapabilityViolation fields:

| Field        | Type    | Meaning                                                                                          |
| ------------ | ------- | ------------------------------------------------------------------------------------------------ |
| `capability` | String  | The capability that was required but not granted.                                                |
| `resource`   | String? | The concrete resource associated with the failure, if any.                                       |
| `context`    | String? | Free-form trace string (e.g. `"window:main"`, `"ipc:fs.read_text"`, `"runtime_request_denied"`). |
| `timestamp`  | Time    | UTC timestamp when the violation was recorded.                                                   |

Additional audit details:

- Violations are **in-memory only** and not persisted across restarts. Drain `app.capabilities.violations` periodically if you need a durable trail.
- Every violation also emits a `Log.warn` entry for integration with your logging pipeline.
- `app.capabilities.audit_log(violation)` is public — custom code can record its own violations.

## Error codes

| Code                           | Raised by                                            | Meaning                                                                                 |
| ------------------------------ | ---------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `CAPABILITY_DENIED`            | `CapabilitySystem#require!`                          | Capability not granted, expired, out of scope, or not allowed for the window.           |
| `SCOPE_DENIED`                 | `ScopeManager#require!`, `Context#require_resource!` | Resource does not match the required scope (path prefix, URL pattern, or process name). |
| `MANIFEST_NOT_FOUND`           | `CapabilitySystem#load_manifest`                     | Configured manifest path does not exist.                                                |
| `PATH_TRAVERSAL`               | `ScopeManager#persist`                               | A persisted scope path contains unsafe traversal sequences.                             |
| `INVALID_PATH`                 | `ScopeManager#persist`                               | Path is empty or malformed.                                                             |
| `IPC_POLICY_RESOURCE_MISSING`  | `ResourceRule#extract`                               | IPC payload does not contain the expected resource field.                               |
| `IPC_SECURITY_CONTEXT_MISSING` | `Router#authorize_frontend_command_impl!`            | Frontend IPC command requires a security context but none is bound.                     |

## Best Practices

- Capability identifiers are exact strings. `clipboard:*` does not grant `clipboard:read` — use the concrete identifier.
- Grant the smallest set of capabilities that lets the app work. Without a manifest, plugins auto-grant their own caps. With a manifest, the manifest and `app.grant(...)` are the sole source of authority — register a plugin but grant only the caps you need.
- Scope filesystem, HTTP, process, and shell access. Use [`app.scopes.persist`](#1-persisted-path-scopes-filesystem) for code-only setups, or the manifest's `scopes` section.
- Prefer the manifest's `scopes` over hand-rolled `app.scopes.persist` calls in production: manifest-driven scopes are mirrored into the persisted `ScopeManager` during `load_manifest`, while `app.scopes.persist` only writes to the persisted store (the in-memory `FsScope` is not updated by it). Mismatched in-memory/persisted state can produce confusing denials.
- Label windows that need different authority. Use [`grant_to_window`](#full-code-api-no-manifest) or the `windows` manifest section.
- Keep public app commands genuinely harmless.
- Put privileged app command policy in `crystkit.json`.
- Let plugin metadata describe plugin command policy.
- Use runtime prompts for user-initiated exceptional access. Use [`on_capability_request`](#full-request-handler-with-reason-and-expiry) when you need the request's reason or expiry in the handler.
- Set a CSP before shipping. Only `AppConfig#csp` reaches the runtime; builder CSP fields are schema-only.
- Review violations during development. Drain `app.capabilities.violations` periodically if you need a durable audit trail.
- For backend defense-in-depth, pass `app.security` to `Features::FileSystem`, `Features::HTTPClient`, `Features::ProcessManager`, etc., or call `app.security.require!` directly.
- Validate plugin-supplied paths yourself before passing them to features. The framework normalizes paths at the scope boundary, but a plugin that interpolates a raw `name` or `dest` into a filesystem path should sanitize the input to `[\w\-]+` so traversal attempts like `../../etc` cannot reach the storage layout at all.

## Next

Read [Plugins](plugins.md) next. Plugins are where most native capabilities enter the app, and their metadata is what makes the security model enforceable before command handlers run.
