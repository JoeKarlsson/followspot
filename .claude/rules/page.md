---
paths:
  - "public/**"
  - "tools/**"
  - "followspot"
---

# Page, tools, and launcher

- There are two positions. `cursor` is confirmed by speech or by the user; `display` is what's highlighted and can coast up to 10 tokens ahead of `cursor`. A match always resets `display` to near `cursor`.
- `public/current.md` is a symlink the launcher creates to the active script (gitignored). The page polls it every 2 s for live edits. A dropped file stops polling until reload.
- `whisper-server --public` follows symlinks, which is what makes live editing work.
- Headless Chrome (`--dump-dom`, `--screenshot`) is the quickest way to check the page renders without errors. `requestAnimationFrame` barely runs there, which is why scrolling snaps on load (`snap = true`) rather than easing.
- On macOS, headless Chrome's `--use-file-for-fake-audio-capture` delivers pure silence (checked with an AnalyserNode). `tools/record-demo.mjs` (`npm run demo`) instead injects a `getUserMedia` replacement via `Page.addScriptToEvaluateOnNewDocument` that plays the WAV through a `MediaStreamDestination`.
- The recorder worklet is routed through a zero-gain node to `destination` so engines that only process pulled nodes still call `process()`. Don't "clean up" that connection.
