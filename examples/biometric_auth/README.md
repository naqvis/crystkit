# Biometric Authentication Example

Demonstrates native biometric authentication (Touch ID / Face ID on macOS, Windows Hello, fprintd on Linux) through the built-in `Biometric` plugin.

## What it demonstrates

- `biometric.available` — detect biometric hardware and its modality.
- `biometric.authenticate` — trigger a system biometric prompt with a custom reason string.
- Gating the feature behind the `biometric:authenticate` capability.

## Run

```bash
# From the project root
crystal run examples/biometric_auth/main.cr
```

Click **Check Availability**, then **Authenticate** and complete the system prompt.
