# Getting Started

This guide builds the smallest useful CrystKit application: one Crystal entrypoint, one typed command, one native window, and one frontend IPC call.

It intentionally stays small. The goal is to get a complete application running before introducing plugins, capability manifests, bundling, or multi-window design. Those pieces are covered after the runtime model is clear.

## Native Prerequisites

The prerequisites below are only the native operating-system libraries that CrystKit links through the bundled `webview` shard and the platform backends.

### macOS

WebKit is provided by macOS. No separate WebView package is needed.

The macOS build requires the developer toolchain used to compile native shards and link C/C++ objects. If the compiler cannot find standard developer tools, install Apple's command line tools:

```sh
xcode-select --install
```

### Linux

Debian/Ubuntu:

```sh
sudo apt install \
  build-essential pkg-config \
  libgtk-3-dev libwebkit2gtk-4.1-dev libjavascriptcoregtk-4.1-dev \
  libglib2.0-dev libx11-dev libxss-dev libdbus-1-dev \
  libnotify-dev libappindicator3-dev libudev-dev libsecret-1-dev \
  fprintd libspeechd-dev libssl-dev
```

Fedora/RHEL:

```sh
sudo dnf install \
  pkgconf-pkg-config \
  gtk3-devel webkit2gtk4.1-devel glib2-devel \
  libX11-devel libXScrnSaver-devel dbus-devel \
  libnotify-devel libappindicator-gtk3-devel systemd-devel \
  libsecret-devel fprintd speech-dispatcher-devel \
  openssl-devel
```

Those packages satisfy CrystKit’s WebView integration and its native-service shard dependencies: GTK/GDK and WebKitGTK for windows and rendering, GLib/GIO/GObject for desktop services, X11/Xss for window-system and idle queries, libnotify for notifications, AppIndicator for tray icons, udev for hardware enumeration, libsecret for safe storage, fprintd for biometric authentication, Speech Dispatcher for speech, and OpenSSL for networking. Clipboard access uses native GTK APIs; it does not invoke clipboard shell tools.

### Windows

Windows needs the normal native build tools plus WebView2.

1. Install **Visual Studio 2022 Build Tools** with the **Desktop development with C++** workload.

2. Install the **Microsoft.Web.WebView2** SDK package. From a developer PowerShell:

```powershell
nuget install Microsoft.Web.WebView2 -OutputDirectory packages
```

That package provides the `WebView2.h` header used when compiling the Windows WebView backend. If the compiler cannot find it, point `CPATH` at the package's native include directory:

```powershell
$pkg = Get-ChildItem .\packages -Filter "Microsoft.Web.WebView2.*" -Directory |
  Sort-Object Name -Descending |
  Select-Object -First 1

$env:CPATH = Join-Path $pkg.FullName "build\native\include"
```

3. Build from **x64 Native Tools Command Prompt for VS 2022** or another shell where the Visual Studio C++ environment is loaded.

Windows 11 already includes the Evergreen WebView2 Runtime. On Windows 10, or on locked-down machines where the Runtime has been removed, install the Evergreen Runtime from Microsoft. The SDK is for compilation; the Runtime is what the app uses when it starts.

Common Windows setup failures:

| Symptom | Fix |
| --- | --- |
| `WebView2.h` cannot be found | Install `Microsoft.Web.WebView2` and set `CPATH` to the package's `build\native\include` directory. |
| Build works in x64 Native Tools but not normal PowerShell | The normal shell is missing the Visual Studio C++ environment. |
| App starts on one machine but not another | The target machine is missing the Evergreen WebView2 Runtime. |

## Create A Project

Use CrystKit's scaffold command. From an installed CLI:

```sh
crystkit init HelloCrystKit
cd HelloCrystKit
```

From a checkout of this repository:

```sh
crystal build src/builder/cli.cr -o bin/crystkit --release
bin/crystkit init HelloCrystKit
cd HelloCrystKit
```

The scaffold creates the project structure, `shard.yml`, `src/main.cr`, `frontend/index.html`, `crystkit.json`, `capabilities.json`, icons, and `.gitignore`, then attempts to run `shards install`.

The rest of this guide uses the scaffolded app as the starting point. The snippets below are simplified for the guide — the actual scaffold includes a menu bar, system tray, and additional commands. Read `src/builder/scaffold/hello/src/main.cr.ecr` for the full generated output.

## Inspect The Frontend

The scaffold creates `frontend/index.html`. Its core idea is this:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Hello CrystKit</title>
  </head>
  <body>
    <main>
      <h1>Hello CrystKit</h1>
      <button id="greet">Greet</button>
      <p id="result"></p>
    </main>

    <script>
      const ipc = window.__CRYSTKIT_IPC__;
      const result = document.querySelector("#result");

      document.querySelector("#greet").addEventListener("click", async () => {
        result.textContent = await ipc.invoke("greet", "Developer");
      });
    </script>
  </body>
</html>
```

`window.__CRYSTKIT_IPC__` is injected by CrystKit when this HTML is loaded inside a CrystKit window. It will not exist in a normal browser tab.

## Inspect The Crystal App

The scaffold also creates `src/main.cr`. The minimal runtime looks like this:

```crystal
require "crystkit"

app = CrystKit::App.new

app.command "greet", String do |name|
  "Hello, #{name}!"
end

app.window(
  title: "Hello CrystKit",
  width: 720,
  height: 480,
  html: File.read("frontend/index.html"),
)

app.run
```

Run it:

```sh
crystal run src/main.cr
```

A native window should open. Click the button and the frontend will call the Crystal `greet` command.

## What Happened

The application has three moving parts:

| Code                          | Responsibility                                                                                                             |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `CrystKit::App.new`           | Creates the runtime owner for windows, IPC, security, plugins, platform services, and lifecycle.                           |
| `app.command "greet", String` | Registers a typed IPC command. The frontend must send a JSON string payload because the Crystal handler expects `String`.  |
| `app.window(...)`             | Creates a native WebView window, loads the HTML, injects the JavaScript bridge, and registers the window with the runtime. |

When the button calls:

```js
await ipc.invoke("greet", "Developer");
```

CrystKit routes the request to the Crystal command, decodes the payload as a `String`, runs the handler, wraps the result, and resolves the JavaScript promise.

The important point is that the frontend did not call an arbitrary string channel. It called a command registered by the Crystal runtime, and the Crystal signature defined the payload shape.

## Where Configuration Fits

This first app does not need `crystkit.json` or `capabilities.json` yet.

Those files become important when the app grows:

- `crystkit.json` tells the CrystKit CLI how to run, build, bundle, and package the project.
- `capabilities.json` declares app-owned authority and resource scopes for native operations such as file access, HTTP requests, dialogs, shell commands, and clipboard access.
- `AppConfig` exposes fields such as app name, identifier, capability manifest path, CSP, and custom protocols.

You will add those pieces when you move from a single-window first app to a project that uses native plugins and the builder workflow.

## Next

Read [Architecture](architecture.md) next. It explains what `App` owns, how a frontend request moves through the router, where security fits, and how windows, plugins, platform services, and lifecycle are connected.

After that, run `crystkit --help` and the relevant subcommand’s `--help` to explore development, build, and packaging options.
