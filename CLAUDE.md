# Followspot

Voice-following browser teleprompter. `whisper-server` (whisper.cpp) does double duty: it serves `public/` as static files and transcribes audio at `/inference`, so the page and the model share one origin and there's no CORS and no second process.

## Commands

```bash
./followspot script.md                  # run it (opens the browser)
./followspot script.md -p 8179 --no-open -- --no-gpu   # alt port, flags after -- go to whisper-server
./followspot download base.en           # fetch a model into models/ (gitignored)
./followspot download vad               # Silero VAD; auto-enabled when present (--no-vad to skip)
npm run check                         # node --check on all JS + bash -n followspot
npm test                              # unit tests (node:test, no deps)
npm run e2e                           # needs a running ./followspot on 8178; macOS only (uses `say`)
node tools/simulate.mjs s.md --port 8179 --skip 3
```

## Architecture

- `public/align.js` is pure: `parseScript` (markdown to paragraphs of word/cue items), `buildTokens` (normalized match tokens that point back at display words), `align` (Smith-Waterman over words around the cursor). All tracking behavior lives here and is unit-tested.
- `public/audio.js` is pure: decimator to 16 kHz, ring buffer, RMS, WAV encoder. Shared with `tools/simulate.mjs`, so the simulator exercises the browser's encoder.
- `public/app.js` is wiring only: settings (localStorage), rendering, the listen loop (250 ms tick, 3.5 s window, silence gate), coast, toolbar, and keys.
- There are two positions. `cursor` is confirmed by speech or by the user; `display` is what's highlighted and can coast up to 10 tokens ahead of `cursor`. A match always resets `display` to near `cursor`.
- The whisper `prompt` is the ~30 script words *behind* the cursor. Don't prompt with upcoming text: Whisper will echo it and the cursor will run ahead of the speaker.

## Rules

- No build step, no runtime deps, no network calls except to the same-origin whisper server.
- Put new logic in a DOM-free module with tests, not in `app.js`.
- Any change to `align.js` needs a unit test for the case, plus an `e2e` / `--skip 3` run before and after.
- Commit each verified change separately with a message that says why.

## Gotchas

- In the maintainer's shell, `node` is an nvm lazy-load function that fails silently in non-interactive shells. Use the absolute binary (`~/.nvm/versions/node/<v>/bin/node`) or put it on PATH first.
- `public/current.md` is a symlink the launcher creates to the active script (gitignored). The page polls it every 2 s for live edits. A dropped file stops polling until reload.
- `whisper-server --public` follows symlinks, which is what makes live editing work.
- The GitHub macOS runner has no usable GPU. CI passes `-- --no-gpu`. Its Homebrew is older and only knows the formula as `whisper-cpp` (newer Homebrew calls it `whisper.cpp` but accepts both), so docs and CI use `whisper-cpp`.
- The Bash tool's shell here is zsh: an unquoted `$args` string is not word-split. Script launcher tests in bash with arrays.
- On macOS, headless Chrome's `--use-file-for-fake-audio-capture` delivers pure silence (checked with an AnalyserNode). `tools/record-demo.mjs` instead injects a `getUserMedia` replacement via `Page.addScriptToEvaluateOnNewDocument` that plays the WAV through a `MediaStreamDestination`.
- The recorder worklet is routed through a zero-gain node to `destination` so engines that only process pulled nodes still call `process()`. Don't "clean up" that connection.
- Headless Chrome (`--dump-dom`, `--screenshot`) is the quickest way to check the page renders without errors. `requestAnimationFrame` barely runs there, which is why scrolling snaps on load (`snap = true`) rather than easing.
