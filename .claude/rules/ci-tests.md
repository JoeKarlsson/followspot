---
paths:
  - ".github/**"
  - "test/**"
  - "tools/simulate.mjs"
  - "examples/sample.md"
---

# CI and tests

- CI speed: Whisper's encoder pads every request to 30 s, so request cost barely depends on clip length. CI passes `-ac 512` (4x faster on CPU) and runs the simulator with `--step 1` (half the requests). The runner is a 3-core virtual M1 whose speed still varies ~5x between runs; the simulator prints median/p90/max latency so slow runs are diagnosable. Thread count was checked and is not the cause (launcher already uses 3).
- `say` occasionally writes an empty file on a fresh runner; `tools/simulate.mjs` retries 3 times and exits 2 with a clear message. PR CI avoids `say` entirely: the required e2e runs on Linux from `test/fixtures` (built whisper-server, cached per CPU-flags hash). macOS runs only after merge, as a non-required smoke test.
- Editing `examples/sample.md` makes the fixtures stale; the simulator exits 3 until you run `npm run fixtures` (macOS `say`) and commit the result.
- The GitHub macOS runner has no usable GPU. CI passes `-- --no-gpu`. Its Homebrew is older and only knows the formula as `whisper-cpp` (newer Homebrew calls it `whisper.cpp` but accepts both), so docs and CI use `whisper-cpp`.
- The Bash tool's shell here is zsh: an unquoted `$args` string is not word-split. Script launcher tests in bash with arrays.
- Simulator by hand: `node tools/simulate.mjs s.md --port 8179 --skip 3`.
