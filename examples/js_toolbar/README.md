# JS-Driven Toolbar Example

A minimal CrystKit app where the **toolbar is created entirely from JavaScript** through the built-in `Toolbar` plugin.

## What it demonstrates

- Granting the `toolbar:manage` capability so the frontend can use toolbar IPC commands.
- Calling `toolbar.add_item`, `toolbar.add_separator` from JS to build a native toolbar.
- Calling `toolbar.show`, `toolbar.hide`, `toolbar.clear`, `toolbar.items` from JS.
- Listening for `toolbar.click` events.

## Run

```sh
crystal run examples/js_toolbar/main.cr
```
