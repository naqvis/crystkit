# NSPanel — macOS floating panels

Create macOS floating panels (`NSPanel`) for your CrystKit app. Convert a regular window into a floating panel that hovers above other windows, or configure it as a utility palette, HUD, or popover.

> **macOS only.** The plugin's no-arg constructor compiles on all platforms; on non-macOS it logs a warning and is inert. Types like `PanelOptions` are only available on macOS and will not compile on other platforms.

## What are panels?

Panels (`NSPanel`) are a special macOS window type that floats above normal windows. They're the standard OS pattern for:

- **Tool palettes** — floating color pickers, inspector panels
- **HUD displays** — compact status overlays
- **Popover windows** — momentary info panels
- **Utility windows** — accessory controls that stay on top

Unlike regular windows, panels can be configured to:

- Float above all applications
- Ignore mouse events (click-through)
- Hide automatically when the app loses focus
- Only become key when necessary (so they don't steal focus)
- Work when modal dialogs are open

## Quick start

### 1. Register the plugin

```crystal
require "crystkit"
require "crystkit/plugins/builtins"

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::NSPanel.new)

app.window(title: "Panel", label: "panel", width: 400, height: 300)
app.run
```

Every window created after the plugin is registered is automatically converted to a borderless NSPanel. No manual conversion needed. Conversion is deferred to the main thread via `dispatch` to ensure the native window handle is fully initialized.

### 2. Configure per-panel options

Pass a `PanelOptions` hash keyed by label to the constructor:

```crystal
app.plugin(CrystKit::Plugins::NSPanel.new({
  "palette" => CrystKit::Plugins::NSPanel::PanelOptions.new(
    floating: true,
    transparent: true,
    movable_by_background: true,
    level: CrystKit::Plugins::NSPanel::Level::Floating,
  )
}))
```

### 3. Show and hide

```crystal
panel = CrystKit::Plugins::NSPanel.find(label)
if p = panel
  p.show              # Show the panel (orderFrontRegardless)
  p.hide              # Hide the panel (orderOut:)
  p.show_and_make_key # Show and focus (makes first responder)
  p.order_front       # Float above all apps
end
```

### 4. Configuration from Crystal

```crystal
panel = CrystKit::Plugins::NSPanel.find(label)

panel.level = CrystKit::Plugins::NSPanel::Level::Status
panel.floating = true
panel.alpha = 0.85
panel.transparent = true
panel.ignores_mouse_events = true
panel.movable_by_background = true
panel.has_shadow = true
panel.collection_behavior =
  CrystKit::Plugins::NSPanel::Behavior::CanJoinAllSpaces |
  CrystKit::Plugins::NSPanel::Behavior::FullScreenAuxiliary
panel.corner_radius = 12.0
panel.works_when_modal = true
panel.hides_on_deactivate = false
panel.accepts_mouse_moved_events = true
panel.style_mask =
  CrystKit::Plugins::NSPanel::Mask::HUDWindow |
  CrystKit::Plugins::NSPanel::Mask::NonactivatingPanel
```

### 5. Restore to regular window

```crystal
panel = CrystKit::Plugins::NSPanel.find(label)
panel.restore  # Changes the panel back to a regular NSWindow via object_setClass
```

After restore, the panel handle is invalidated (`valid?` returns `false`).

## PanelOptions reference

All fields are nilable — unset fields use NSPanel defaults or the plugin-level `DEFAULTS` (borderless, level 4, floating true).

| Field | Type | Description |
|-------|------|-------------|
| `style_mask` | `UInt64?` | Window style mask (see Mask constants) |
| `level` | `Int64?` | Window level (see Level constants) |
| `floating` | `Bool?` | Whether the panel behaves as a floating panel |
| `ignores_mouse_events` | `Bool?` | Mouse events pass through the panel |
| `transparent` | `Bool?` | Sets opaque to false + clear background |
| `titlebar_transparent` | `Bool?` | Titlebar appears transparent |
| `movable_by_background` | `Bool?` | Drag by clicking anywhere on the panel |
| `drag_mode` | `Symbol?` | `:background` or `:css_region` |
| `has_shadow` | `Bool?` | Whether the panel has a shadow |
| `collection_behavior` | `Int64?` | Spaces/Fullscreen behavior |
| `works_when_modal` | `Bool?` | Panel remains usable when modal dialogs are open |
| `becomes_key_only_if_needed` | `Bool?` | Only becomes key when necessary |
| `hides_on_deactivate` | `Bool?` | Hide when the app loses focus |
| `accepts_mouse_moved_events` | `Bool?` | Track mouse movement events |
| `alpha` | `Float64?` | Opacity from 0.0 to 1.0 |
| `corner_radius` | `Float64?` | Corner radius via contentView layer |
| `hover_activate` | `Bool?` | Auto-activate + focus on mouse hover (requires tracking area) |

## Activation policy

The NSPanel plugin supports setting the app's `NSApplication` activation policy, which controls how the app behaves in the dock and menu bar:

```crystal
app.plugin(CrystKit::Plugins::NSPanel.new(
  {} of String => CrystKit::Plugins::NSPanel::PanelOptions,
  activation_policy: 1_i64  # NSApplicationActivationPolicyRegular
))
```

Common activation policy values:

| Value | Constant | Behavior |
|-------|----------|----------|
| `0` | `NSApplicationActivationPolicyRegular` | Normal dock icon + menu bar |
| `1` | `NSApplicationActivationPolicyAccessory` | No dock icon, menu bar only |
| `2` | `NSApplicationActivationPolicyProhibited` | No dock icon, no menu bar (agent) |

This is useful for background/agent apps that run in the menu bar and show panels on demand.

## Drag modes

The panel supports two drag modes controlled by `drag_mode`:

| Mode | Behavior |
|------|----------|
| `:background` | Drag anywhere on the panel background to move it. Uses `sendEvent:` override to intercept `NSLeftMouseDown`, `NSLeftMouseDragged`, and `NSRightMouseDragged`. |
| `:css_region` | CSS `-webkit-app-region: drag` regions in the webview control dragging. The default NSWindow behavior. |

When `movable_by_background` is set to `true`, the drag mode is automatically set to `:background`.

The `sendEvent:` override stores the initial mouse-down location and computes frame position deltas during drag, moving the panel via `setFrameOrigin:`.

## Hover activation

When `hover_activate` is enabled in `PanelOptions`:

1. A hover-check timer fires every 50ms via `performSelector:withObject:afterDelay:`
2. When the mouse enters the panel frame, the app is activated (`activateIgnoringOtherApps:`) and the panel becomes key
3. JavaScript runs to focus a `<textarea>` in the webview
4. When the mouse leaves, `document.activeElement.blur()` is called
5. A `@@mouse_inside` hash tracks per-panel hover state

Useful for popover-style panels that should appear when hovered and automatically gain keyboard focus.

## Constants reference

### `CrystKit::Plugins::NSPanel::Level`

Window level constants mapped to raw `NSWindow` level values:

| Constant | Value | Description |
|----------|-------|-------------|
| `Normal` | 0 | Normal window level |
| `Floating` | 4 | Floats above normal windows |
| `ModalPanel` | 8 | Modal panel level |
| `Status` | 25 | Status bar level |
| `PopUpMenu` | 101 | Pop-up menu level |
| `ScreenSaver` | 1000 | Above screen saver |

Additional raw constants available in `CrystKit::Platform::MacOS::Panel`: `NSDOCK_WINDOW_LEVEL` (22), `NSMAIN_MENU_WINDOW_LEVEL` (24).

### `CrystKit::Plugins::NSPanel::Mask`

Style mask constants:

| Constant | Value | Description |
|----------|-------|-------------|
| `Borderless` | 0 | No window decorations |
| `NonactivatingPanel` | 128 | Panel doesn't activate the app on click |
| `HUDWindow` | 8192 | Dark HUD window style |
| `UtilityWindow` | 16 | Utility panel with small title bar |

Combine masks with `|`:

```crystal
panel.style_mask =
  CrystKit::Plugins::NSPanel::Mask::HUDWindow |
  CrystKit::Plugins::NSPanel::Mask::NonactivatingPanel
```

### `CrystKit::Plugins::NSPanel::Behavior`

Collection behavior constants:

| Constant | Value | Description |
|----------|-------|-------------|
| `Default` | 0 | Standard behaviour |
| `CanJoinAllSpaces` | 1 | Visible on all Spaces |
| `FullScreenAuxiliary` | 256 | Stays visible over full-screen apps |
| `FullScreenPrimary` | 128 | Primary full-screen window |
| `Stationary` | 16 | Stays in place |
| `IgnoresCycle` | 64 | Skip in window cycle |

Combine with `|`:

```crystal
panel.collection_behavior =
  CrystKit::Plugins::NSPanel::Behavior::CanJoinAllSpaces |
  CrystKit::Plugins::NSPanel::Behavior::FullScreenAuxiliary |
  CrystKit::Plugins::NSPanel::Behavior::IgnoresCycle
```

## Panel class methods

The `CrystKit::Plugins::NSPanel::Panel` wrapper class provides:

### Visibility

| Method | Description |
|--------|-------------|
| `show` | Show the panel (`orderFrontRegardless`) |
| `hide` | Hide the panel (`orderOut:`) |
| `show_and_make_key` | Show, make first responder, and make key |
| `order_front` | Order front regardless of app state |
| `visible?` | Check if panel is visible |

### Window state

| Method | Description |
|--------|-------------|
| `make_key` | Make the panel the key window |
| `resign_key` | Resign key window status |
| `can_become_key?` | Check if panel can become key |

### Configuration getters/setters

| Method | Description |
|--------|-------------|
| `level` / `level=` | Get/set window level |
| `floating?` / `floating=` | Get/set floating panel status |
| `style_mask` / `style_mask=` | Get/set style mask |
| `alpha` / `alpha=` | Get/set opacity |
| `transparent=` | Set transparent (opaque + background color) |
| `ignores_mouse_events=` | Set mouse event passthrough |
| `titlebar_transparent=` | Set titlebar transparency |
| `movable_by_background=` | Set movable by background |
| `drag_mode=` | Set drag mode (`:background` or `:css_region`) |
| `has_shadow=` | Set shadow visibility |
| `collection_behavior=` | Set collection behavior |
| `works_when_modal=` | Control behavior while a modal window is active |
| `hides_on_deactivate=` | Set hide-on-deactivate |
| `hides_on_deactivate?` | Check hide-on-deactivate setting |
| `accepts_mouse_moved_events=` | Set mouse-moved event tracking |
| `corner_radius=` | Set corner radius |

### Lifecycle

| Method | Description |
|--------|-------------|
| `restore` | Convert back to NSWindow. Handle becomes null. |
| `valid?` | Returns `false` after `restore` |

## Complete example: floating control panel

A floating control panel that stays on top of all Spaces:

```crystal
# main.cr
require "crystkit"
require "crystkit/plugins/builtins"

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::NSPanel.new({
  "panel" => CrystKit::Plugins::NSPanel::PanelOptions.new(
    floating: true,
    level: CrystKit::Plugins::NSPanel::Level::Floating,
    collection_behavior:
      CrystKit::Plugins::NSPanel::Behavior::CanJoinAllSpaces |
      CrystKit::Plugins::NSPanel::Behavior::FullScreenAuxiliary,
    movable_by_background: true,
    corner_radius: 12.0,
  )
}))

app.command "app.toggle_panel" do
  panel = CrystKit::Plugins::NSPanel.find("panel")
  if p = panel
    if p.visible?
      p.hide
    else
      p.show_and_make_key
    end
  end
end

app.window(
  title: "Control Panel",
  label: "panel",
  width: 300,
  height: 400,
  html: "<h1>Control Panel</h1><p>Floating on all Spaces</p>",
)
app.run
```

## Complete example: agent app with HUD panel

A menu-bar-only agent app with a HUD-style info panel:

```crystal
require "crystkit"
require "crystkit/plugins/builtins"

app = CrystKit::App.new

# No dock icon — accessory agent app
app.plugin(CrystKit::Plugins::NSPanel.new(
  {
    "hud" => CrystKit::Plugins::NSPanel::PanelOptions.new(
      style_mask:
        CrystKit::Plugins::NSPanel::Mask::HUDWindow |
        CrystKit::Plugins::NSPanel::Mask::NonactivatingPanel,
      level: CrystKit::Plugins::NSPanel::Level::Status,
      floating: true,
      transparent: true,
      alpha: 0.9,
      corner_radius: 16.0,
      collection_behavior:
        CrystKit::Plugins::NSPanel::Behavior::CanJoinAllSpaces |
        CrystKit::Plugins::NSPanel::Behavior::FullScreenAuxiliary,
      hides_on_deactivate: true,
      hover_activate: true,
    )
  },
  activation_policy: 1_i64 # Accessory — no dock icon
))

app.command "hud.toggle" do
  panel = CrystKit::Plugins::NSPanel.find("hud")
  panel.try { |p| p.visible? ? p.hide : p.show_and_make_key }
end

app.window(
  title: "System HUD",
  label: "hud",
  width: 320,
  height: 200,
  transparent: true,
  html: "<h1>System Status</h1><p>CPU: 12% | Mem: 8.2 GB</p>",
)
app.run
```

## How it works

The plugin uses the Objective-C runtime's `object_setClass` function to change the class of an existing `NSWindow` to `NSPanel` at runtime. This avoids the need to create a new window — any existing CrystKit window can be promoted to a panel.

### Class swizzling

`CrystKit::Platform::MacOS` allocates a custom `CrystKitPanel` class as a subclass of `NSPanel` via `objc_allocateClassPair`, then overrides:

| Method | Override behavior |
|--------|-------------------|
| `canBecomeKeyWindow` | Always returns `YES` |
| `isFloatingPanel` | Always returns `YES` |
| `canBecomeMainWindow` | Always returns `YES` |
| `sendEvent:` | Implements background drag mode by intercepting mouse events |

The `ns_window_to_panel` function:
1. Sets the style mask to `NSNonactivatingPanelMask`
2. Sets the window level to `NSFloatingWindowLevel`
3. Disables `hidesOnDeactivate`
4. Stores the original class for restoration
5. Calls `object_setClass` to swap to `CrystKitPanel`

### Panel registry

Under the hood, the `CrystKit::Platform::MacOS` module manages:

- An internal registry of panel handles keyed by window label
- Safe autorelease-pool scoped ObjC message sends
- Restoration: `panel_to_window` changes the class back to `NSWindow` so the window behaves normally on close
- A `@@drag_modes` hash keyed by pointer address to track per-panel drag behavior
- A `@@mouse_inside` hash for hover tracking state

### Event handling overrides

The `sendEvent:` override in `CrystKitPanel` intercepts mouse events for background dragging:
- `NSLeftMouseDown` (type 1): stores initial click location
- `NSLeftMouseDragged`/`NSRightMouseDragged` (types 6/7): computes delta and calls `setFrameOrigin:` to move the panel
- All other events are forwarded to the original `NSWindow sendEvent:` implementation

## Working with modal dialogs

The `works_when_modal` option allows panels to remain interactive when a modal dialog is open. This is useful for inspector panels that need to remain accessible:

```crystal
app.plugin(CrystKit::Plugins::NSPanel.new({
  "inspector" => CrystKit::Plugins::NSPanel::PanelOptions.new(
    works_when_modal: true,
    level: CrystKit::Plugins::NSPanel::Level::ModalPanel,
    floating: true,
  )
}))
```

## Removing panels

You can remove a panel from the registry (does not destroy the native window):

```crystal
CrystKit::Plugins::NSPanel.remove("my_panel")
```

This calls `unregister_panel` in the macOS module, which removes the handle from `@@panels`, `@@original_classes`, and `@@mouse_inside`.

## Related guides

- [Windows](windows.md) — window configuration basics
- [Plugins](plugins.md) — built-in plugin system
