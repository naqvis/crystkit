# Cross-Platform Support

CrystKit supports macOS, Linux, and Windows. Applications use the same `CrystKit::Features` and `CrystKit::Plugins` APIs on every platform; platform selection is automatic.

This guide describes CrystKit’s framework surface. The backing shards document their own native implementation details and platform constraints.

## Platform Support

| Platform | WebView | Status |
| --- | --- | --- |
| macOS | Cocoa / WebKit | Supported |
| Linux | GTK 3 / WebKitGTK | Supported |
| Windows | Win32 / WebView2 | Supported |

## Framework Feature Matrix

### Runtime and windows

| Feature | macOS | Linux | Windows |
| --- | --- | --- | --- |
| App creation, IPC, events, and channels | ✅ | ✅ | ✅ |
| Multi-window and per-window security | ✅ | ✅ | ✅ |
| Frameless, transparent, modal, and fullscreen windows | ✅ | ✅ | ✅ |
| Minimize to tray and custom titlebars | ✅ | ✅ | ✅ |
| NSPanel | ✅ | — | — |

NSPanel is a CrystKit-specific extension of its WebView windows and remains macOS-only.

### Desktop integration

CrystKit exposes native desktop controls through Features for Crystal code and Plugins for frontend IPC. Their native implementations, support matrix, required desktop services, and platform limitations are documented in the [`native_desktop` platform guide](https://github.com/naqvis/native_desktop/blob/main/guides/platform-support.md).

CrystKit adds capability enforcement, JSON-facing models, event forwarding, window ownership, and application lifecycle to those services.

File-type registration is exposed through the app-owned `app.file_associations` feature. CrystKit supplies the application identity and executable to `native_desktop` and routes its activation stream into file associations. URL activations are routed into the deep-link feature, while the activations plugin exposes the complete extensible stream to frontend code.

### System services

| Feature | macOS | Linux | Windows |
| --- | --- | --- | --- |
| System, locale, storage, network, and display information | ✅ | ✅ | ✅ |
| DPI monitoring for CrystKit windows | ✅ | ✅ | ✅ |
| Speech synthesis and voice discovery | ✅ AppKit | ✅ Speech Dispatcher | ✅ SAPI |
| Speech recognition and language discovery | ✅ Speech.framework | — No standard system STT service | ✅ Installed SAPI recognizers |

Host operating-system, hardware, storage, network, display, locale, and application-directory snapshots are implemented by `system_info`. Theme, power, idle, CPU, hardware enumeration and monitoring, biometric authentication, speech, session lifecycle, OS permissions, activations, and trash are implemented through CrystKit features backed by `native_desktop`.

### Storage, networking, and processes

| Feature | macOS | Linux | Windows |
| --- | --- | --- | --- |
| Key-value store | ✅ | ✅ | ✅ |
| Safe credential storage | ✅ | ✅ | ✅ |
| File watching | ✅ | ✅ | ✅ |
| HTTP, WebSocket, and local server | ✅ | ✅ | ✅ |
| Process, shell, and sidecar execution | ✅ | ✅ | ✅ |
| Printing and PDF export | ✅ | ✅ | ✅ |

## Runtime Availability

A check mark means CrystKit has an implementation for that platform. It does not guarantee that optional hardware, a desktop service, or a compositor capability exists on every machine.

Use the CrystKit feature API for runtime checks:

```crystal
biometric = CrystKit::Features::BiometricAuth.new
if biometric.available?
  result = biometric.authenticate("Unlock vault")
end

hardware = CrystKit::Features::HardwareAPI.new
if hardware.available?(CrystKit::Features::HardwareAPIType::Bluetooth)
  devices = hardware.enumerate(CrystKit::Features::HardwareAPIType::Bluetooth)
end
```

Frontend code should reach these services through the corresponding plugin instead of importing a platform module or a backing shard.

The Speech plugin exposes synthesis under `speech:synth` and recognition
under `speech:recognize`. Recognition languages are discovered at runtime
through `speech.recognize_languages`; frontend code should select one of those
BCP 47 tags and may separately query current recognizer availability. macOS
applications that use recognition must include microphone and speech
recognition usage descriptions in their bundle configuration.

## Ownership Boundary

CrystKit keeps the parts coupled to its runtime:

- WebView creation and event-loop integration
- custom `crystkit://` protocol handling
- WebView DevTools and permission wiring
- enhanced CrystKit window behavior
- printing WebView content
- NSPanel integration

General native desktop controls live in [`native_desktop`](https://github.com/naqvis/native_desktop); credential storage, host information, and file watching live in their respective shards. CrystKit features adapt those APIs to its capability model, execution contexts, plugins, and IPC protocol.

## See Also

- [Architecture](architecture.md)
- [Plugins](plugins.md)
- [Windows](windows.md)
- [Testing](testing.md)
