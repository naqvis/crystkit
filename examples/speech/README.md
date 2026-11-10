# Speech Example

Demonstrates text-to-speech and speech-to-text through the built-in `Speech` plugin.

## What it demonstrates

- TTS: `speech.speak`, `speech.stop`, `speech.pause`, `speech.resume`.
- STT: `speech.recognize_languages`, `speech.recognize_request_permission`, `speech.recognize_start`, `speech.recognize_stop`.
- Listening for `speech.recognition_result`, `speech.recognition_error`, and `speech.recognition_end`.
- Separating the `speech:synth` and `speech:recognize` capabilities.

## Run

```bash
# From the project root
crystal run examples/speech/main.cr
```

## Notes

Recognition requires a system STT service (macOS Speech.framework, Windows SAPI). Linux reports an empty language list because it has no standard OS-level STT service.
