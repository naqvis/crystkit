# crystkit:// Asset Protocol

Demonstrates serving webview assets through the `crystkit://` custom URL scheme backed by `virtualfs` — **no TCP server, no HTTP listener, no port bound**. This is the Tauri-style asset model adapted for CrystKit.

## Run

### Dev (serves from `frontend/` directory)

```bash
crystal run examples/asset_protocol/main.cr
```

The `frontend_dist` path is set in code via `AppConfig.new(frontend_dist: "...")`. In a real project, `crystkit.json` sets `build.frontend_dist` and `crystkit dev` picks it up automatically.

Or via the builder CLI:

```bash
crystkit dev
```

### Production (bundled `.vpak` archive)

```bash
crystkit build          # compiles the binary
crystkit bundle         # packages assets.vpak + binary into an installer
```

The bundler automatically builds `resources/assets.vpak` from your `frontend_dist` directory. At runtime `AssetLoader` finds it next to the binary and mounts it — no manual pak building needed.

## What you'll see

A 720x800 window with four test cards:

1. **Page loaded via protocol** — confirms the page origin is `crystkit://localhost/`
2. **Fetch a JSON asset** — `fetch("data.json")` resolves against the protocol origin
3. **Load an image** — `<img src="logo.svg">` served from the same protocol
4. **SPA-style route** — `fetch("settings")` (extensionless) falls back to `index.html`

Open the WebKit Inspector (right-click → Inspect Element, debug mode is enabled) to verify in the Network tab that all requests go to `crystkit://localhost/` — no `http://localhost:PORT` anywhere.

## How it works

```
crystkit://localhost/index.html
        │
        ▼
 WKURLSchemeHandler  (macOS — swizzled into WKWebView at init)
        │  native callback → Crystal resolver proc
        ▼
 CustomProtocol.build_resolver
        │
        ▼
 VfsAssetSource.fetch("/index.html")
        │
        ▼
 VirtualFs::Vfs
    dev:  OsDir(frontend_dist)
    prod: mounted assets.vpak (BlockStore decompresses on read)
```

The `App` auto-wires this when no explicit `html:` or `url:` is passed to `window()`. `AssetLoader` searches for assets in this order:

1. `assets.vpak` next to the binary / in `resources/` / in the app bundle (production)
2. `frontend_dist` from `AppConfig` (dev — set via code or `crystkit.json`)

## Key code

```crystal
app = CrystKit::App.new

# No html: or url: — the app auto-navigates to crystkit://localhost/
app.window(title: "crystkit:// Asset Protocol", width: 720, height: 800)

app.run
```

That's it. The framework handles scheme registration, Vfs mounting, and navigation automatically.

## Verify no TCP is used

While the app is running:

```bash
lsof -i -P | grep LISTEN | grep -v mDNS
```

You should see no listener on any crystkit-related port. All assets are served in-process through the native webview scheme handler.
