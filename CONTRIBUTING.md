# Contributing

Thanks for helping. This is a small project with a few firm constraints, so a quick read here saves a round trip on your pull request.

## Ground rules

- **No build step, no runtime dependencies.** `public/` is plain ES modules served directly by `whisper-server`. If a change needs a bundler or an npm package at runtime, open an issue first.
- **Audio stays local.** Nothing in the page may send audio, transcripts, or scripts anywhere but the local whisper server.
- **Keep the logic testable.** Matching lives in `public/align.js` and audio math in `public/audio.js`. Neither touches the DOM, so both run under `node --test`. Put new logic there (or in a new DOM-free module), and keep `app.js` as the wiring.

## Setup

```bash
brew install whisper-cpp ffmpeg shellcheck   # macOS; ffmpeg is only for the tools/ scripts
npm install                                  # dev tooling only (Biome); nothing ships from node_modules
./followspot download base.en
./followspot download vad
./followspot examples/sample.md
```

## Before you open a pull request

```bash
npm run format     # apply Biome's formatting and safe fixes
npm run lint       # Biome lint + format check, and ShellCheck on the launcher
npm run check
npm test
npm run e2e        # with ./followspot running
```

CI runs all of these except `format`, and `main` only accepts pull requests where they pass.

- **If you change matching** (`align.js`), add a unit test for the case you're fixing. Also run the simulator on a longer script, straight and with `--skip 3`, and put the before/after "Finished at" lines in the PR description.
- **If you change the page,** try it in a browser with a real microphone. The tests can't hear you.
- **Keep commits small and focused,** with messages that explain why.

## Style

Formatting is automated, so don't hand-format. [Biome](https://biomejs.dev/) (config in `biome.json`) formats and lints the JavaScript, JSON, and CSS: 2-space indent, double quotes, semicolons, trailing commas, 110-column lines. `.editorconfig` covers everything else. VS Code will offer the Biome, ShellCheck, and EditorConfig extensions and format on save.

What the tools can't check:

- **Plain browser JavaScript.** ES modules, no TypeScript, no framework, no transpile. If it doesn't run when `whisper-server` serves it as-is, it doesn't go in.
- **Pure logic stays pure.** `align.js` and `audio.js` never touch the DOM or `window`, so they stay testable under Node.
- **Comments explain why,** not what: the constraint, the trap, the reason a simpler version didn't work.
- **The launcher is bash 3.2-safe,** since that's what macOS ships. No associative arrays or `mapfile`, and guard empty arrays with `${arr[@]+"${arr[@]}"}` under `set -u`.
- **Commit messages** get a short imperative subject and a body that says why.

`git blame` skips the one-time formatting commit if you run `git config blame.ignoreRevsFile .git-blame-ignore-revs` once.

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
biome.json               lint + format config
```

## Reporting bugs

Use the bug report template. The two most useful things to include are what the status panel showed (latency and the last thing it heard) and the passage of script where tracking went wrong.
