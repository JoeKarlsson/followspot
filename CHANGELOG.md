# Changelog

## Unreleased

### Added

- A native macOS app (`macos/`). The prompter page runs in its own window, with a bundled static whisper-server (Metal) and an app icon. CI builds a DMG for every push, and attaches it to the GitHub Release for each `v*` tag.
  - A scripts folder (`~/Documents/Followspot` by default). The control window can switch, create, and edit scripts.
  - Settings (⌘,): microphone and camera, model, VAD, fast mode, keep the display awake while listening, hide from screen recordings, float on top, port, and extra whisper-server flags.
  - Global ⌃⌥ shortcuts that work while another app is in front.
  - Model downloads are verified against Hugging Face's SHA-256 and resume after a dropped connection.
  - Fast mode (`-ac 512`) is on by default for medium and large models. It measured about 3x faster on large-v3-turbo, but slower in the worst case on base.en, so small models run without it.
  - CI checks that the app passes whisper-server the same flags as `./followspot`.
- The prompter remembers your place in each script (the 50 most recent), recognizing a script by its opening words and finding your spot again after edits. R starts over.
- Presentation clickers and foot pedals: Page Up / Page Down move by paragraph, and B or `.` (a clicker's "blank screen" button) toggles listening.
- The settings dialog lists microphones and cameras as soon as the page can see their names, instead of only after the next start.

### Fixed

- A short final phrase after a pause (e.g. "the script.") now finishes the script instead of leaving the highlight two words short.

### Changed

- Linux is now tested: CI builds whisper-server from source and runs the end-to-end check on Ubuntu for every pull request. The README has the build steps.
- The end-to-end check replays recorded speech fixtures (`npm run e2e`, any OS) instead of needing macOS `say`; `npm run fixtures` re-records them.
- `FOLLOWSPOT_THREADS` overrides the launcher's thread count, and it prints the value at startup.

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
