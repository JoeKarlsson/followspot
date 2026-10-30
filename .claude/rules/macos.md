---
paths:
  - "macos/**"
---

# macOS app (`macos/`)

## Commands

```bash
macos/build-whisper.sh && macos/build.sh --install   # native app → /Applications/Followspot.app
macos/make-signing-identity.sh          # once per Mac: stable local signature, so rebuilds keep TCC permissions
macos/test.sh                           # Swift checks for the app's non-UI code (plain swiftc, no Xcode needed)
macos/package.sh                        # dist/Followspot-<version>.dmg (CI does this on every push)
macos/check-args.sh "$HOME/Library/Application Support/Followspot/server.args" -m models/<m>.bin -- <flags>  # app vs launcher flags
macos/icon/make-icns.sh [png]           # regenerate the app icon (drawn in make-icon.swift, or from a PNG)
```

## Architecture

- `macos/` is a thin Swift wrapper around the same page. It runs the bundled whisper-server on 8177 with the launcher's flags, serves a staging folder of symlinks (`~/Library/Application Support/Followspot/www`, with `current.md` pointing at the open script), and shows it in a WKWebView. Keep behavior in `public/`: the app should need no page changes. App and page talk two ways (`Bridge.swift`): the app joins the page's BroadcastChannel via an injected user script (sending actions and settings, reading listening state), and the page calls `webkit.messageHandlers.followspot` through `public/native.js` for app-only features (scripts list, save, create). The page never passes a path to write: saves go to the open script, and new scripts are created by name in the scripts folder.
- Release builds (`build.sh`, `-c release`) never look outside the bundle and Application Support; `Paths.repo` (the checkout's `models/`, `public/`, `macos/.whisper/`) exists only in debug `swift run` builds.

## Gotchas

- SwiftPM owns `macos/.build/`, and anything else in there makes `swift build` fail with no error output. That's why the whisper.cpp checkout lives in `macos/.whisper/`.
- With only the Command Line Tools (no Xcode), Swift macro plugins are missing: SwiftUI's `@State` and Swift Testing's `@Test`/`#expect` fail to compile. The app keeps view state in `ObservableObject`s, and `macos/test.sh` compiles `Tests/Checks.swift` with the Foundation-only sources and a tiny `expect()` runner. A source file the checks need must stay free of AppKit/SwiftUI.
- The app's `localStorage` is keyed by origin, and the origin includes the port. That's why the port is fixed (8177). Changing it resets the page's saved settings in the app.
- `defaults write … -array` stores `--` literally and numbers as numbers. `extraArgs` is read as `[Any]`, so don't switch it back to `stringArray`.
- Fast mode (`-ac 512`) only applies to models of 1 GB and up: measured 3x faster on large-v3-turbo, but base.en's worst request doubled. The same holds for the `followspot` launcher, which never adds `-ac 512` itself (pass it after `--`). Resolve symlinks before checking model size (linked models otherwise read as a few bytes).
- In an untyped (`Any`) dictionary, `url.path` can resolve to the `path(percentEncoded:)` method rather than the property. WebKit then silently drops the whole bridge reply and the page's promise never settles. Use `path(percentEncoded: false)`. `Bridge` now rejects replies that aren't valid JSON, and `Checks.swift` covers the reply shapes.
- The prompter publishes state at least once a second: the control window treats 2 s of silence as "prompter closed" and re-requests everything (it used to flicker and re-run script handling while idle).

## Driving the app in tests

- Type into the app with a CGEvent `postToPid` helper (events can only reach that process). System Events `keystroke`/`key code` go to whatever is frontmost and have typed into the user's terminal. Use targeted AX clicks and menu items for everything else.
- System Events can click WKWebView content through the accessibility tree (`entire contents of window …` gives the paths), and `pmset -g assertions` shows whether "Followspot is listening" is holding the display awake. WebKit's `<select>` popups don't expose their items; open them and use arrow keys. Controls show up in the accessibility tree even when they're laid out at zero size, so also check `size of` the containing area (a grouped SwiftUI `Form` has no height of its own).
