// The prompter (app.js) and the control window (control.js) talk over a
// BroadcastChannel. The prompter owns all state: the control window only
// sends commands and mirrors what the prompter reports back.
//
//   control -> prompter: { type: "hello" }            ask for a full state
//                        { type: "action", name }     same as a key press
//                        { type: "set", key, value }  change one setting
//                        { type: "jump", word }       move to a display word
//   prompter -> control: { type: "script", text }
//                        { type: "state", ... }       see publish() in app.js

export const CHANNEL = "followspot";

// Keyboard shortcuts, shared so a key does the same thing whichever window
// has focus.
const KEYS = {
  " ": "listen",
  ArrowRight: "wordNext",
  ArrowLeft: "wordPrev",
  ArrowDown: "paraNext",
  ArrowUp: "paraPrev",
  r: "restart",
  R: "restart",
  Home: "restart",
  c: "camera",
  C: "camera",
  m: "mirror",
  M: "mirror",
  "+": "bigger",
  "=": "bigger",
  "-": "smaller",
  _: "smaller",
  "]": "wider",
  "[": "narrower",
  h: "hud",
  H: "hud",
  f: "fullscreen",
  F: "fullscreen",
  s: "settings",
  S: "settings",
};

// The action for a keydown, or null. Cmd/Ctrl/Alt combos belong to the
// browser (Cmd+R must still reload, not restart the script).
export function keyAction(e) {
  if (e.metaKey || e.ctrlKey || e.altKey) return null;
  return Object.hasOwn(KEYS, e.key) ? KEYS[e.key] : null;
}

// Allowed range for each numeric setting.
export const LIMITS = {
  fontSize: [20, 160],
  columnWidth: [20, 100],
  readingLine: [10, 90],
  marginTop: [0, 45],
  marginBottom: [0, 45],
  windowSec: [1.5, 8],
  gate: [0, 0.1],
  coast: [0, 5],
  cameraOpacity: [5, 80],
};

// Set one setting, clamped to its range. Unknown keys and values of the
// wrong type are refused (returns false), so a stray message can't corrupt
// the saved settings.
export function applySetting(settings, defaults, key, value) {
  if (!Object.hasOwn(defaults, key) || typeof value !== typeof defaults[key]) return false;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return false;
    const [lo, hi] = LIMITS[key] ?? [-Infinity, Infinity];
    value = Math.min(hi, Math.max(lo, value));
  }
  settings[key] = value;
  return true;
}
