import assert from "node:assert/strict";
import { test } from "node:test";
import { align, buildTokens, normalize, numToWords, parseScript, tokenizeHeard } from "../public/align.js";

const SCRIPT = `# Title

**Format:** Short-form
**Words:** ~50

---

*[Screen: the app.]*

Muse can read your Gmail and book you a dinner reservation. But out of the box, it can't see your work apps.

*[TEXT OVERLAY: 3 steps.]*

Step one. In GitHub, go to Settings, then Personal Access Tokens. Click Create, name it something like "muse connector," and copy it right away.

Now ask it something real. "Which pull requests have had no activity in thirty days?"

---

## Shot list

1. Record the thing
`;

const tokensFor = (md) => buildTokens(parseScript(md));
const norms = (md) => tokensFor(md).map((t) => t.norm);

test("parseScript keeps only the body between the first two rules", () => {
  const paras = parseScript(SCRIPT);
  assert.equal(paras.length, 5);
  const text = paras
    .flat()
    .filter((i) => i.type === "word")
    .map((i) => i.text)
    .join(" ");
  assert.ok(!text.includes("Format"));
  assert.ok(!text.includes("Record"));
});

test("cues are kept for display but never become match tokens", () => {
  const paras = parseScript(SCRIPT);
  assert.equal(paras[0][0].type, "cue");
  assert.equal(paras[0][0].text, "Screen: the app.");
  assert.ok(!norms(SCRIPT).includes("overlay"));
});

test("a plain file without rules is used whole", () => {
  assert.deepEqual(norms("Hello there.\n\nSecond part."), ["hello", "there", "second", "part"]);
});

test("normalize folds contractions, punctuation, hyphens, and digits", () => {
  assert.deepEqual(normalize("It's"), ["its"]);
  assert.deepEqual(normalize('"connector,"'), ["connector"]);
  assert.deepEqual(normalize("right-click"), ["right", "click"]);
  assert.deepEqual(normalize("30"), ["thirty"]);
  assert.deepEqual(numToWords(1234), ["one", "thousand", "two", "hundred", "thirty", "four"]);
});

test("tokenizeHeard drops whisper non-speech markers", () => {
  assert.deepEqual(tokenizeHeard("[BLANK_AUDIO] (music) okay go"), ["okay", "go"]);
});

test("align follows a clean read from the start", () => {
  const t = tokensFor(SCRIPT);
  const r = align(t, 0, tokenizeHeard("Muse can read your Gmail and book you"));
  assert.ok(r);
  assert.equal(t[r.pos - 1].norm, "you");
});

test("align tolerates misheard words", () => {
  const t = tokensFor(SCRIPT);
  const start = t.findIndex((x) => x.norm === "step");
  const r = align(t, start, tokenizeHeard("step one in get hub go to setting then personal access"));
  assert.ok(r);
  assert.equal(t[r.pos - 1].norm, "access");
});

test("align matches digits the speaker said as words", () => {
  const t = tokensFor(SCRIPT);
  const start = t.findIndex((x) => x.norm === "which");
  const r = align(t, start, tokenizeHeard("have had no activity in 30 days"));
  assert.ok(r);
  assert.equal(t[r.pos - 1].norm, "days");
});

test("align refuses to move on unrelated speech", () => {
  const t = tokensFor(SCRIPT);
  assert.equal(align(t, 5, tokenizeHeard("sorry let me start that over hold on")), null);
});

test("align will not leap far ahead on thin evidence", () => {
  const t = tokensFor(SCRIPT);
  // "something" appears only far ahead of the cursor; one lucky word is not enough.
  assert.equal(align(t, 0, tokenizeHeard("uh something")), null);
});

test("align finishes on a short phrase said right at the cursor", () => {
  // After a pause, the last window may hold only "the script." (1 + 2 = 3).
  const t = tokensFor("When you pick back up, so does the script.");
  const at = t.findIndex((x) => x.norm === "the");
  const r = align(t, at, tokenizeHeard("the script."));
  assert.ok(r);
  assert.equal(r.pos, t.length);
});

test("the short-phrase allowance doesn't apply further ahead", () => {
  const t = tokensFor("one two three four five six seven eight nine ten, and then the script ends.");
  assert.equal(align(t, 0, tokenizeHeard("the script")), null);
});

test("common words alone never move the cursor, even right at it", () => {
  const t = tokensFor("so does the script and the end.");
  const at = t.findIndex((x) => x.norm === "the");
  assert.equal(align(t, at, tokenizeHeard("the and the")), null);
});

test("align prefers the nearest copy of a repeated phrase", () => {
  const md =
    "go to the next step now. filler words here to pad the gap out a bit more. go to the next step now.";
  const t = tokensFor(md);
  const r = align(t, 0, tokenizeHeard("go to the next step"));
  assert.ok(r);
  assert.ok(r.pos < 8);
});
