# File Manager

A professional two-panel file manager built from the auto-registered commands of four plugins: `Plugins::FS`, `Plugins::Dialog`, `Plugins::Notifications`, and `Plugins::Clipboard`.

## Run

```bash
crystal run examples/file_manager/main.cr
```

## What you'll see

A 1100×750 window with a dark theme:

- **Sidebar** — quick links to Home, Desktop, Documents, Downloads, and the temp directory used as the demo root
- **Toolbar** — Up, Refresh, New File, New Folder, Copy Path, Paste, Delete
- **Breadcrumb** — clickable path segments for fast navigation
- **File table** — sorted directories-first, with file type icons, formatted sizes, and timestamps
- **Editor panel** — opens on double-click for text files, with a Save button
- **Status bar** — item count and current path
- **Toast notifications** — non-intrusive feedback for all operations

### Keyboard shortcuts

| Key | Action |
|-----|--------|
| Backspace | Go up one directory |
| Delete | Delete selected file |
| Ctrl/⌘+C | Copy selected file path |
| Ctrl/⌘+N | New file |
| Ctrl/⌘+R | Refresh |

## What's wired

```crystal
app.grant("fs:read", "fs:write", "fs:delete", "dialog:open", "dialog:save",
          "notification:show", "clipboard:read", "clipboard:write")
app.plugin(CrystKit::Plugins::FS.new)
app.plugin(CrystKit::Plugins::Dialog.new)
app.plugin(CrystKit::Plugins::Notifications.new)
app.plugin(CrystKit::Plugins::Clipboard.new)
```

The FS plugin registers `fs.read_text`, `fs.write_text`, `fs.list_dir`, `fs.exists`, `fs.metadata`, `fs.remove_file`, `fs.create_dir`, `fs.copy`, `fs.move`. The frontend invokes them directly:

```js
const entries = await ipc.invoke("fs.list_dir", { path: "/tmp" });
const text = await ipc.invoke("fs.read_text", { path: "/tmp/foo.txt" });
await ipc.invoke("fs.write_text", { path: "/tmp/foo.txt", content: "hello" });
```

## Capabilities

The grants in this example are scoped to the user's home directory:

```crystal
app.scopes.persist(home, CrystKit::Security::Permission::Write)
```

After that, `fs.write_text` will only succeed for paths under `home` and the FS plugin's underlying `Features::FileSystem` will reject everything else.

## Plugin reference

- [`Plugins::FS`](../../docs/plugins.md#webviewpluginsfs) — full command list
- [`Plugins::Dialog`](../../docs/plugins.md#webviewpluginsdialog) — open / save / folder dialogs
- [`Plugins::Notifications`](../../docs/plugins.md#webviewpluginsnotifications) — desktop notifications
- [`Plugins::Clipboard`](../../docs/plugins.md#webviewpluginsclipboard) — clipboard read/write
- [`docs/security.md`](../../docs/security.md) — capabilities and scopes
