# Permissions Example

Demonstrates CrystKit's webview permission model — camera, microphone, and geolocation — with runtime prompts and persisted default policies (macOS).

## What it demonstrates

- `Plugins::Permissions` plus a custom `on_request` handler that answers with a native confirm dialog.
- `permissions.request_demo`, `permissions.set_default`, `permissions.reset`, and `permissions.status` commands.
- Using `navigator.mediaDevices.getUserMedia` after a permission is granted.

## Run

```bash
# From the project root
crystal run examples/permissions/main.cr
```

Click **Request Camera/Microphone/Geolocation** to trigger a native prompt, or set explicit default policies with the Grant/Deny buttons.
