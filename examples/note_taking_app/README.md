# Note-Taking App

A two-pane notes UI demonstrating the `Plugins::Store` plugin. Notes persist across restarts via a JSON file under the app's storage directory.

## Run

```bash
crystal run examples/note_taking_app/main.cr
```

## What you'll see

An 800×600 window with:

- A sidebar listing all notes (titles only)
- A "+ New" button to start a new note
- An editor with a title field and a body textarea
- Save and Delete buttons

Type a title and body, click Save. Restart the app — the note is still there. The store auto-persists to a JSON file under the app's data directory (`~/Library/Application Support/<app-id>/store/store_notes.json` on macOS).

## What's wired

```crystal
app.plugin(CrystKit::Plugins::Store.new)
```

That's the entire backend. The plugin registers `store.get`, `store.set`, `store.delete`, `store.keys`, `store.has`, `store.clear`. The frontend manages note records as JSON values keyed by an auto-generated id, plus a special `_index` key holding the array of all ids.

## Storage layout

The Store plugin uses one JSON file per namespace:

```
~/Library/Application Support/app.crystkit/
  scopes.json                          # capability scopes
  store/
    store_notes.json                   # this app's notes
    store_<other_namespace>.json
```

Each `store_<ns>.json` is a flat `{key: value}` object — values can be strings, numbers, booleans, arrays, or full JSON objects.

## Storage paths and AppConfig

The default app identifier is `app.crystkit`. To use your own, pass an `AppConfig`:

```crystal
config = CrystKit::AppConfig.new(identifier: "com.example.notes")
app = CrystKit::App.new(config)
```

The storage dir is then derived from the OS conventions:

| OS      | Path                                                               |
| ------- | ------------------------------------------------------------------ |
| macOS   | `~/Library/Application Support/<identifier>/`                      |
| Linux   | `$XDG_DATA_HOME/<identifier>/` (or `~/.local/share/<identifier>/`) |
| Windows | `%APPDATA%\<identifier>\`                                          |

## Frontend pattern

```js
// Save
await ipc.invoke("store.set", ["notes", "note-1234", { title, body }]);

// Read
const note = await ipc.invoke("store.get", ["notes", "note-1234"]);

// List
const ids = await ipc.invoke("store.get", ["notes", "_index"]);
```

## See also

- [`Plugins::Store`](../../docs/plugins.md#webviewpluginsstore) — full command list
- [`guides/recipes.md`](../../guides/recipes.md) — persistence patterns
