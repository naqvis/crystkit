# CrystKit Documentation

CrystKit applications are built around one runtime-owned `CrystKit::App`. The app owns windows, typed IPC, security, plugins, platform services, and lifecycle. The documentation is organized to teach those pieces in the order a developer normally meets them while building a real desktop application.

## Recommended Path

Read these guides in order if you are learning CrystKit:

1. [Getting started](getting-started.md) Build the smallest complete app: one `App`, one command, one window, one frontend IPC call.

2. [Plugins](plugins.md) Add native features (dialogs, clipboard, FS, tray, notifications) with built-in plugins.

3. [IPC](ipc.md) Understand the typed boundary between Crystal and JavaScript: command signatures, payload shapes, events, channels, reactive state, error envelopes, and policy.

4. [Windows](windows.md) Multi-window apps, lifecycle, labels, parent-child relationships, and capability inheritance.

5. [Security](security.md) Capabilities, scopes, manifests, per-window grants, runtime prompts, and CSP.

6. [Recipes](recipes.md) Common patterns: reactive state, streaming, shutdown veto, tray menus, persistence, and more.

7. [Architecture](architecture.md) The runtime internals — for when you want to understand why it works.

8. [Testing](testing.md) Verify behavior with the `FakeFrontend` harness and spec patterns.

9. [Cross-platform](cross-platform.md) Platform support matrix for each feature and package target.

## Choose A Path

### I Am Evaluating CrystKit

Start with the project [README](../README.md), then read [Architecture](architecture.md). Together they explain what CrystKit owns, what your application owns, and why the framework is structured around one `App`.

### I Want To Build My First App

Read [Getting started](getting-started.md), then [Plugins](plugins.md). The first guide gives you a working app; the second shows how to add native features.

### I Already Have A Frontend

CrystKit is frontend-framework-agnostic — point the webview at any URL. Read [IPC](ipc.md) to learn the typed boundary, then [Plugins](plugins.md) to see which native features are available.

### I Need Native Desktop Features

For a CrystKit application, read [Plugins](plugins.md) first, then [Recipes](recipes.md) for common patterns. Native features are exposed as plugin commands, protected by capabilities, and called through frontend IPC. Crystal backend code uses the matching Feature.

For native implementation details, host integration, resource ownership, and platform constraints, read the [`native_desktop` guides](https://github.com/naqvis/native_desktop/tree/main/guides). CrystKit-specific extensions such as [NSPanel](nspanel.md) remain documented here.

### I Am Reviewing Security

Read [Security](security.md), then [IPC](ipc.md), then [Plugins](plugins.md). Security depends on the relationship between frontend command authority, plugin metadata, application grants, resource scopes, and per-window restrictions.

### I Am Packaging An App

Run `crystkit build --help` and `crystkit bundle --help` for CLI usage. Read [Cross-platform](cross-platform.md) for the platform support matrix.

### I Need Exact API Details

Run `crystal docs` to generate API documentation from inline source comments. Use `crystkit --help` for CLI commands, and [Cross-platform](cross-platform.md) for platform support.

## Source Layout

```text
src/
  app/        App and AppConfig (composition root)
  core/       Core runtime, lifecycle, windows, errors, native window
  ipc/        Router, codec, schema, channels, and JavaScript bridge
  state/      Backend-owned reactive state slices and JSON Patch propagation
  plugins/    Plugin protocol, registry, and built-in plugin adapters
  platform/   CrystKit-specific WebView and window integration
  features/   Crystal-facing features and standalone-shard adapters
  security/   Capability, scope, manifest, and permission services
  builder/    Builder config, build pipeline, bundlers, and CLI (see `crystkit --help`)
```

The source code and compiled examples are authoritative when platform behavior differs by operating system. The guides explain the model; `crystal docs` generates API documentation from inline source comments.
