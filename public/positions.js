// Where you were in each script, so reopening it (or relaunching) picks up
// there instead of at the top. Pure: app.js keeps the store in localStorage.
//
// A script is recognized by its opening words, since the page only ever sees
// current.md and never a file name. A position is saved as a token index plus
// the few words there, so edits above your place don't lose it.

const KEY_TOKENS = 12;
const CONTEXT = 4;
const MAX_SCRIPTS = 50;

// Identity for a script: its first dozen normalized words.
export function scriptKey(tokens) {
  return tokens
    .slice(0, KEY_TOKENS)
    .map((t) => t.norm)
    .join(" ");
}

function contextAt(tokens, i) {
  return tokens
    .slice(i, i + CONTEXT)
    .map((t) => t.norm)
    .join(" ");
}

// A new store with this script's position recorded, keeping the most recent
// MAX_SCRIPTS scripts. Positions at the very start aren't worth keeping.
export function rememberPosition(store, tokens, cursor, now = Date.now()) {
  const key = scriptKey(tokens);
  if (!key) return store;
  const next = { ...store };
  if (cursor <= 0) delete next[key];
  else next[key] = { i: cursor, ctx: contextAt(tokens, cursor), at: now };
  const keys = Object.keys(next);
  if (keys.length > MAX_SCRIPTS) {
    keys.sort((a, b) => next[b].at - next[a].at);
    for (const old of keys.slice(MAX_SCRIPTS)) delete next[old];
  }
  return next;
}

// Where to start this script: the saved place, found again by its words if
// the script was edited since; the top if it's new, or if you'd reached the
// end last time (so a finished take starts over).
export function restorePosition(store, tokens) {
  const saved = store?.[scriptKey(tokens)];
  if (!saved || !Number.isInteger(saved.i) || tokens.length === 0) return 0;
  if (saved.i >= tokens.length - CONTEXT) return 0;
  if (contextAt(tokens, saved.i) === saved.ctx) return saved.i;
  // Edited: the nearest place with the same words, else the same index.
  let best = -1;
  for (let i = 0; i + CONTEXT <= tokens.length; i++) {
    if (
      contextAt(tokens, i) === saved.ctx &&
      (best < 0 || Math.abs(i - saved.i) < Math.abs(best - saved.i))
    ) {
      best = i;
    }
  }
  return best >= 0 ? best : Math.min(saved.i, tokens.length - 1);
}
