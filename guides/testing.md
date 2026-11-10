# Testing

CrystKit’s test suite is designed to run without opening a WebView. Framework behavior is tested through narrow provider and backend seams; the standalone native shards have their own platform-level suites.

## Run the Suite

```sh
crystal spec
```

Run one area while developing:

```sh
crystal spec spec/clipboard_spec.cr
crystal spec spec/ipc_router_spec.cr
```

`spec/spec_helper.cr` loads CrystKit and the test providers used throughout the suite.

## Test Boundaries

Tests follow component ownership:

- CrystKit specs test capability checks, model conversion, IPC registration, lifecycle, event forwarding, and interaction with a provider.
- A standalone shard’s specs test its FFI, platform behavior, resource ownership, and public native API.
- End-to-end example testing verifies that the two layers are wired together correctly on a real desktop.

Do not make a CrystKit unit spec depend on a user machine’s clipboard contents, enrolled biometrics, installed voices, example files, or other ambient state.

## Included Test Providers

| Test type | Production seam |
| --- | --- |
| `Test::FakeWindowBackend` | `Platform::WindowBackend` |
| `Test::FakeWindowIntegrationBackend` | `Platform::WindowIntegrationBackend` |
| `Test::FakeClipboardProvider` | `Features::Clipboard::Provider` |
| `Test::FakeSpeechSynthesizer` | `NativeDesktop::SpeechSynthesizer` used by `Features::SpeechSynthesizer` |
| `Test::FakeSpeechRecognizer` | `NativeDesktop::SpeechRecognizer` used by `Features::SpeechRecognizer` |
| `Test::FakeThemeProvider` | `Features::SystemTheme::Provider` |
| `Test::FakePowerProvider` | `Features::PowerMonitor::Provider` |
| `Test::FakeIdleProvider` | `Features::IdleMonitor::Provider` |
| `Test::FakeCpuProvider` | `Features::CpuMonitor::Provider` |
| `Test::FakeDPIProvider` | `Features::DPIMonitor::Provider` |
| `Test::FakeToolbarProvider` | `Features::Toolbar::Provider` |
| `Test::FakeFrontend` | JavaScript bridge stand-in over the real IPC router |

## Testing a Feature Adapter

Inject the provider and assert CrystKit behavior around it:

```crystal
require "./spec_helper"

describe CrystKit::Features::Clipboard do
  it "checks capabilities and delegates text storage" do
    capabilities = CrystKit::Security::CapabilitySystem.new
    capabilities.grant("clipboard:read")
    capabilities.grant("clipboard:write")

    provider = CrystKit::Test::FakeClipboardProvider.new
    clipboard = CrystKit::Features::Clipboard.new(capabilities, provider)

    clipboard.write_text("hello")
    clipboard.read_text.should eq("hello")
    provider.text.should eq("hello")
  end
end
```

This verifies CrystKit’s contract without asserting GTK, AppKit, or Win32 behavior a second time.

## Testing Windows Headlessly

`SpecHelpers.with_fake_window_app` creates an `App` with `FakeWindowBackend`, so window creation follows the normal registry and wiring path without constructing a native window:

```crystal
SpecHelpers.with_fake_window_app do |app|
  window = app.window(title: "Main", label: "main", width: 640, height: 480)

  window.label.should eq("main")
  app.window_registry.primary.should eq(window)
end
```

For a custom combination, inject the specific backend into `Platform::Services`:

```crystal
backend = CrystKit::Test::FakeWindowBackend.new
services = CrystKit::Platform::Services.new(window: backend)

SpecHelpers.with_temp_dir do |dir|
  app = CrystKit::App.new(
    CrystKit::AppConfig.new(storage_dir: Path[dir]),
    platform: services,
  )
  # exercise the app
end
```

Only the remaining CrystKit-owned WebView integration is injected through `Platform::Services`. Native desktop feature adapters use their own provider seams.

## Testing IPC with `FakeFrontend`

`FakeFrontend` invokes the real router and captures backend-to-frontend events without a WebView:

```crystal
require "./spec_helper"
require "../src/test/fake_frontend"

SpecHelpers.with_temp_dir do |dir|
  app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
  app.command("greet", String) { |name| "Hello, #{name}" }

  frontend = CrystKit::Test::FakeFrontend.new(app)
  begin
    response = frontend.invoke("greet", JSON::Any.new("Crystal"))
    response.ok?.should be_true
    response.value.not_nil!.as_s.should eq("Hello, Crystal")
  ensure
    frontend.detach
  end
end
```

Always detach the frontend in `ensure`; capture hooks and subscriptions otherwise leak into later examples.

`FakeFrontend#channel(id)` captures streamed channel values, and `FakeFrontend#state(name)` observes reactive state updates.

## Testing Security

Test denial and success separately:

```crystal
capabilities = CrystKit::Security::CapabilitySystem.new
clipboard = CrystKit::Features::Clipboard.new(
  capabilities,
  CrystKit::Test::FakeClipboardProvider.new,
)

expect_raises(CrystKit::Core::SecurityError) do
  clipboard.read_text
end

capabilities.grant("clipboard:read")
clipboard.read_text.should eq("")
```

For filesystem operations, use a temporary directory and grant only that path. Do not use a real home directory or machine-wide path in a spec.

## Testing Plugins

Plugin specs should verify:

- metadata declares every registered command and event
- command policy matches the resource being accessed
- payloads are decoded into the intended type
- cleanup releases listeners and owned resources

Invoke commands through `FakeFrontend` when the test needs the complete frontend policy path. Direct router invocation is suitable for focused codec or registration tests.

## Platform Source Contracts

Some specs inspect platform source structure to catch accidental shell fallbacks, duplicate FFI declarations, or missing compile-time branches. These are source-contract tests, not substitutes for native execution.

Run the relevant shard’s specs on each supported operating system before publishing platform changes. CrystKit’s headless suite then verifies the adapter and plugin layers independently.

## See Also

- [Architecture](architecture.md)
- [Security](security.md)
- [Plugins](plugins.md)
- [Cross-platform support](cross-platform.md)
