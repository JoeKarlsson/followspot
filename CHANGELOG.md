# Changelog

## 0.1.0 (2026-09-24)

### Added

- Voice-following browser teleprompter backed by a local whisper.cpp server.
- Fuzzy speech-to-script alignment that tolerates misheard, skipped, and ad-libbed words.
- Whisper prompt built from the words just read, for better spelling of names.
- Coast mode that keeps the script moving when you're talking but nothing has matched yet.
- Hover control bar: text size, column width, top and bottom margins, reading line, mirror, and fullscreen.
- Click any word to jump there.
- Markdown scripts with ignored header and footer sections and dimmed stage directions; live reload on save; drag and drop.
- `./followspot` launcher with model discovery, `download` subcommand, and passthrough flags for whisper-server. Works on macOS and Linux.
- Voice activity detection: `./followspot download vad` fetches the Silero VAD model, and the launcher enables it automatically when present (`--no-vad` to opt out). Silence and room noise no longer produce phantom words.
- Unit tests, a `say`-based end-to-end simulator, and GitHub Actions CI.
- README demo GIF, recorded through the real pipeline by `tools/record-demo.mjs`.
