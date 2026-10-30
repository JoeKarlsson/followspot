# Followspot

Voice-following browser teleprompter. `whisper-server` (whisper.cpp) does double duty: it serves `public/` as static files and transcribes audio at `/inference`, so the page and the model share one origin and there's no CORS and no second process.

Area detail loads from `.claude/rules/` when you touch matching files: `macos.md` (the Swift app), `page.md` (`public/`, `tools/`, the launcher), `ci-tests.md` (CI, tests, fixtures).

## Commands

```bash
./followspot script.md                  # run it (opens the browser)
./followspot script.md -p 8179 --no-open -- --no-gpu   # flags after -- go to whisper-server
npm test                                # unit tests; npm run e2e replays fixtures vs ./followspot on 8178
```

## Architecture

- `public/align.js` is pure: `parseScript` (markdown to paragraphs of word/cue items), `buildTokens` (normalized match tokens that point back at display words), `align` (Smith-Waterman over words around the cursor). All tracking behavior lives here and is unit-tested.
- `public/audio.js` is pure: decimator to 16 kHz, ring buffer, RMS, WAV encoder. Shared with `tools/simulate.mjs`, so the simulator exercises the browser's encoder.
- `public/app.js` is wiring only: settings (localStorage), rendering, the listen loop (250 ms tick, 3.5 s window, silence gate), coast, toolbar, and keys.
- The whisper `prompt` is the ~30 script words *behind* the cursor. Don't prompt with upcoming text: Whisper will echo it and the cursor will run ahead of the speaker.

## Rules

- No build step, no runtime deps, no network calls except to the same-origin whisper server.
- Put new logic in a DOM-free module with tests, not in `app.js`.
- Run `npm run format` before committing; CI fails on unformatted code (`biome ci`). Biome is a dev dependency only: `public/` must never import from `node_modules`.
- Any change to `align.js` needs a unit test for the case, plus an `e2e` / `--skip 3` run before and after.
- Commit each verified change separately with a message that says why.

## Gotchas

- In the maintainer's shell, `node` is an nvm lazy-load function that fails silently in non-interactive shells. Use the absolute binary (`~/.nvm/versions/node/<v>/bin/node`) or put it on PATH first.
