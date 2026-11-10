# JS-Driven Menus Example

A minimal CrystKit app where the **menubar and tray menu are created entirely from JavaScript** through the built-in `MenuBar` and `Tray` plugins.

## What it demonstrates

- Granting capabilities from Crystal so the frontend can use plugin IPC commands.
- Calling `menu.build` from JS to install a native menu bar.
- Calling `tray.create` from JS to create a tray icon with a context menu.
- Listening for `menu.click`, `tray.click`, and `tray.menu_click` events.

## Run

```sh
crystal run examples/js_menus/main.cr
```
