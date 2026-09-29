// The macOS app's side channel (macos/Sources/Followspot/Bridge.swift). In a
// browser there's no handler, so the app-only features that use it (the
// script list and editor in the control window) stay hidden.

// A function that sends a request to the app and resolves with its reply,
// or null outside the app.
export function appBridge(win = globalThis) {
  const handler = win.webkit?.messageHandlers?.followspot;
  if (!handler) return null;
  return (type, args = {}) => handler.postMessage({ type, ...args });
}

// The file name for a new script from what was typed, or null if it can't
// be one. The app checks again (Scripts.fileName in Scripts.swift).
export function scriptFileName(input) {
  const name = String(input ?? "").trim();
  if (!name || name.startsWith(".") || /[/:\\]/.test(name)) return null;
  return /\.(md|txt)$/i.test(name) ? name : `${name}.md`;
}

// What a new script starts with: the same layout as examples/sample.md, so
// notes above the first rule and a shot list below the second are ignored.
export const NEW_SCRIPT = `# Notes (not read aloud)

---

Your script goes here. Each paragraph is a chunk you can jump between.

---

Anything after the second rule is ignored too, like a shot list.
`;
