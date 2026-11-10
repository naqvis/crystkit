# NSPanel Examples

macOS floating panel (`NSPanel`) examples for CrystKit. Each subdirectory is a complete, runnable example.

> **macOS only.** These examples use the `NSPanel` plugin which requires the Objective-C runtime and AppKit.

## Examples

| Example | What it demonstrates |
|---|---|
| [`basic/`](basic) | Auto-converted borderless NSPanel — open panel via `window`. |
| [`panel_builder/`](panel_builder) | Floating tool palette with transparent background, rounded corners, movable by background, visible on all spaces. |
| [`fullscreen/`](fullscreen) | Panel visible above fullscreen apps using `FullScreenAuxiliary` collection behavior. |
| [`mouse_tracking/`](mouse_tracking) | Dark-themed panel with live mouse coordinate display and alpha control. |
| [`hover_activate/`](hover_activate) | Panel with hover activation — auto-focuses and activates the app on mouse enter. |
| [`levels/`](levels) | Interactive demo of window levels — Normal (0), Floating (4), PopUp Menu (101), Status (25), Screen Saver (1000). |
| [`styles/`](styles) | Interactive demo of style masks — Borderless (0) and Non-Activating (128). |

## Running

```bash
# From the project root
crystal run examples/nspanel/basic/main.cr

# Or any other example
crystal run examples/nspanel/levels/main.cr
```

## What you'll see

### basic
A simple borderless NSPanel with static text. Demonstrates the minimal setup: just an `app.window` with the `NSPanel` plugin installed.

### panel_builder
A floating tool palette with tool icons (Select, Rectangle, Ellipse, Pencil, Text). The palette has a transparent background, rounded corners, and is draggable by the drag handle. Works on all Spaces.

### fullscreen
An overlay panel that stays visible even when other apps are in fullscreen mode, using `FullScreenAuxiliary` collection behavior.

### mouse_tracking
A dark-themed panel showing live mouse X/Y coordinates. An IPC command (`app:set_alpha`) is registered for alpha control.

### hover_activate
A panel with hover activation — the panel activates the app and focuses a textarea when the mouse enters, and blurs it when the mouse leaves. Draggable via `movable_by_background: true`.

### levels
Five buttons create panels at Normal (0), Floating (4), PopUp Menu (101), Status (25), and Screen Saver (1000) levels. Each panel is color-coded and offset so you can see the stacking order.

### styles
Two buttons create panels with different style masks: Borderless (no decorations) and Non-Activating (doesn't activate the app on click).

## How the examples work

Each example:

1. Creates an `App` and registers the `NSPanel` plugin
2. Registers Crystal-side `app.command` handlers that call into `CrystKit::Platform::MacOS` panel functions
3. Creates an `app.window` with inline HTML/JS frontend
4. The frontend calls `ipc.invoke` to trigger panel operations

Example backend command pattern:

```crystal
app.command "app:create_level_panel", Int64 do |level|
  label = "panel-#{count}"
  child = app.window(title: "Panel", label: label, ...)
  panel = CrystKit::Plugins::NSPanel.find(label)
  panel.level = level
  panel.show
end
```

Example frontend pattern:

```js
const ipc = window.__CRYSTKIT_IPC__;
ipc.invoke('app.create_level_panel', LEVELS.NORMAL);
```

## Next steps

- See the [NSPanel guide](../../guides/nspanel.md) for full API reference
- See the [Plugins guide](../../guides/plugins.md) for the plugin protocol
