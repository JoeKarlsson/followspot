# Contributing

Thanks for helping. This is a small project with a few firm constraints, so a quick read here saves a round trip on your pull request.

## Ground rules

- **No build step, no runtime dependencies.** `public/` is plain ES modules served directly by `whisper-server`. If a change needs a bundler or an npm package at runtime, open an issue first.
- **Audio stays local.** Nothing in the page may send audio, transcripts, or scripts anywhere but the local whisper server.
- **Keep the logic testable.** Matching lives in `public/align.js` and audio math in `public/audio.js`. Neither touches the DOM, so both run under `node --test`. Put new logic there (or in a new DOM-free module), and keep `app.js` as the wiring.

## Setup

```bash
brew install whisper-cpp ffmpeg     # macOS; ffmpeg is only for tools/simulate.mjs
./followspot download base.en
./followspot examples/sample.md
```

## Before you open a pull request

```bash
npm run check
npm test
npm run e2e        # with ./followspot running
```

- **If you change matching** (`align.js`), add a unit test for the case you're fixing. Also run the simulator on a longer script, straight and with `--skip 3`, and put the before/after "Finished at" lines in the PR description.
- **If you change the page,** try it in a browser with a real microphone. The tests can't hear you.
- **Keep commits small and focused,** with messages that explain why.

## Project layout

```
followspot               launcher: picks a model, links the script, starts whisper-server
public/index.html        page markup (toolbar, settings dialog)
public/style.css         styles; layout driven by CSS variables set from settings
public/app.js            wiring: mic capture, listen loop, rendering, controls
public/align.js          script parsing and speech-to-script alignment (pure)
public/audio.js          decimator, ring buffer, RMS, WAV encoder (pure)
public/recorder-worklet.js  AudioWorklet that forwards mic samples
public/demo.md           demo script (first run, README GIF)
test/                    node:test unit tests
tools/simulate.mjs       say + whisper-server end-to-end read-through
tools/record-demo.mjs    records docs/demo.gif through the real pipeline (headless Chrome)
examples/                sample scripts
```

## Reporting bugs

Use the bug report template. The two most useful things to include are what the status panel showed (latency and the last thing it heard) and the passage of script where tracking went wrong.
