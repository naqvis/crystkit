# FluxReader

A local-first desktop RSS/Atom reader built with CrystKit, demonstrating all framework plugins and features.

## Features

- Subscribe to RSS/Atom feeds
- Three-pane resizable UI: sidebar (categories/feeds), article list, reader
- Full-text search over the in-memory article store
- Mark read/unread, favorites, mark all read
- OPML import/export with system file dialogs
- Background feed refresh every 60 seconds (auto-refresh loop)
- System tray with unread count tooltip and tray menu
- Pop-out article reader windows
- Desktop notifications for new articles (macOS bundle-only)
- Context menus on feeds, articles, and view headers (native platform menus)
- Deep-link subscription (`fluxreader://subscribe?url=...`)
- Single-instance enforcement
- Settings modal: Appearance, Notifications, Startup Behavior, Autostart, Data Management, About, Error Log
- Autostart on login (via framework autostart plugin)
- Error toast with simplified user-friendly messages and close button
- Feed error indicators (⚠ for feeds with errors)
- Hide empty feeds/categories toggle (persisted across sessions)
- Resizable sidebar (140–400px) and article-list pane (180–500px)
- Keyboard shortcuts for all major actions
- Dark-only theme

## Run

From the CrystKit project root:

```sh
crystal run examples/fluxreader/main.cr
```

## Keyboard shortcuts

| Shortcut      | Action             |
| ------------- | ------------------ |
| `Cmd+N`       | Subscribe to feed  |
| `Cmd+R`       | Refresh all feeds  |
| `Cmd+,`       | Open settings      |
| `Cmd+1`       | View: All Articles |
| `Cmd+2`       | View: Unread       |
| `Cmd+3`       | View: Favorites    |
| `Cmd+Shift+N` | Mark all read      |
| `Cmd+Alt+I`   | Toggle DevTools    |
| `Cmd+Q`       | Quit               |
| `Cmd+W`       | Hide window        |

## IPC commands

### Feeds

| Command              | Params                             | Description                    |
| -------------------- | ---------------------------------- | ------------------------------ |
| `feeds.list`         | —                                  | List all feeds                 |
| `feeds.add`          | `url: String, category: String?`   | Subscribe to a feed            |
| `feeds.remove`       | `id: Int64`                        | Unsubscribe a feed             |
| `feeds.set_category` | `feed_id: Int64, category: String` | Change feed category           |
| `feeds.categories`   | —                                  | List all category names        |
| `feeds.refresh`      | `feed_id: Int64`                   | Refresh a single feed          |
| `feeds.refresh_all`  | —                                  | Refresh all feeds (background) |

### Articles

| Command                    | Params      | Description                     |
| -------------------------- | ----------- | ------------------------------- |
| `articles.list`            | `ListRec`   | List articles with filters      |
| `articles.get`             | `id: Int64` | Get single article              |
| `articles.mark_read`       | `id: Int64` | Mark article as read            |
| `articles.mark_unread`     | `id: Int64` | Mark article as unread          |
| `articles.mark_all_read`   | `ListRec`   | Mark all matching articles read |
| `articles.toggle_favorite` | `id: Int64` | Toggle favorite state           |
| `articles.counts`          | —           | Get all/unread/favorites counts |
| `articles.fetch_content`   | `id: Int64` | Fetch full article content      |

### Search

| Command        | Params        | Description           |
| -------------- | ------------- | --------------------- |
| `search.query` | `SearchQuery` | FTS5 full-text search |

### OPML

| Command       | Params         | Description          |
| ------------- | -------------- | -------------------- |
| `opml.import` | `path: String` | Import OPML file     |
| `opml.export` | `path: String` | Export feeds as OPML |

### Reader

| Command              | Params        | Description                    |
| -------------------- | ------------- | ------------------------------ |
| `reader.popout`      | `id: Int64`   | Open article in pop-out window |
| `reader.open_window` | `url: String` | Open URL in external browser   |

### Data

| Command      | Description                     |
| ------------ | ------------------------------- |
| `data.clear` | Clear all data and window state |

## UI events (emitted to frontend)

| Event               | Payload                              | Trigger                     |
| ------------------- | ------------------------------------ | --------------------------- |
| `ui:show_settings`  | `{}`                                 | Menu/Tray/Settings shortcut |
| `ui:show_subscribe` | `{}` or `{"url": "..."}`             | Menu, deep link             |
| `ui:import_opml`    | `{}`                                 | Menu → Import OPML          |
| `ui:export_opml`    | `{}`                                 | Menu → Export OPML          |
| `ui:set_view`       | `{"view": "all\|unread\|favorites"}` | Menu, keyboard shortcut     |
| `ui:mark_all_read`  | `{}`                                 | Menu, keyboard shortcut     |
| `feed:updated`      | `{"id": ..., "title": "..."}`        | After feed refresh          |
| `feed:error`        | `{"feed_id": ..., "message"}`        | On feed fetch failure       |

## Context menu actions

- **Article** (right-click article in list): Mark Read, Toggle Favorite, Pop Out
- **Feed** (right-click feed in sidebar): Refresh Feed, Change Category…, Remove Feed
- **View header** (right-click section title): Mark All Read

All context menu actions go through `contextmenu.show` → `handleCtxAction` in the frontend, which dispatches the appropriate IPC command. Feed context menu sends the feed ID via a `data-feed-id` attribute. Article context menu sends the article ID via a `data-article-id` attribute.

## Deep links

FluxReader registers the `fluxreader://` URL scheme on your system.

### Supported commands

#### `fluxreader://subscribe?url=<feed-url>`

Opens the subscribe dialog with the feed URL pre-filled.

### How it works

1. On startup, FluxReader registers `fluxreader://` as a custom protocol handler via `CrystKit::Features::DeepLink`.
2. When a `fluxreader://` URL is opened (e.g., by clicking a link in a browser or running `open fluxreader://subscribe?url=...` in a terminal), the operating system launches FluxReader and passes the URL to it.
3. If FluxReader is already running, the single-instance layer forwards the URL to the running instance.
4. The deep link handler parses the URL and emits a `deeplink:subscribe` event, which triggers `ui:show_subscribe` with the feed URL.
5. The frontend opens the subscribe modal with the URL already filled in.

### Examples

```sh
# From a terminal (macOS):
open "fluxreader://subscribe?url=https://example.com/feed.xml"

# From a web page:
<a href="fluxreader://subscribe?url=https://blog.example.com/rss">Subscribe in FluxReader</a>
```

### Startup URL

You can also pass a `fluxreader://` URL as a command-line argument when launching:

```sh
crystal run examples/fluxreader/main.cr -- "fluxreader://subscribe?url=https://example.com/feed.xml"
```
