import assert from "node:assert/strict";
import { test } from "node:test";
import { buildTokens, parseScript } from "../public/align.js";
import { rememberPosition, restorePosition, scriptKey } from "../public/positions.js";

const tokensOf = (md) => buildTokens(parseScript(md));

const SCRIPT = `Welcome back to the kitchen. Today we're making the easiest loaf of bread you'll ever bake.

First, warm the water until it feels like a bath. Stir in the yeast and wait ten minutes.

Then add the flour and salt, and mix until there's no dry flour left.

Cover it and let it rise overnight on the counter.`;

test("a new script starts at the top", () => {
  assert.equal(restorePosition({}, tokensOf(SCRIPT)), 0);
  assert.equal(restorePosition(null, tokensOf(SCRIPT)), 0);
});

test("reopening a script resumes where you were", () => {
  const tokens = tokensOf(SCRIPT);
  const store = rememberPosition({}, tokens, 20);
  assert.equal(restorePosition(store, tokensOf(SCRIPT)), 20);
});

test("edits above your place don't lose it", () => {
  const tokens = tokensOf(SCRIPT);
  const at = tokens.findIndex((t) => t.norm === "flour");
  const store = rememberPosition({}, tokens, at);
  const edited = SCRIPT.replace("Stir in the yeast", "Stir in two teaspoons of the yeast");
  const newTokens = tokensOf(edited);
  const back = restorePosition(store, newTokens);
  assert.equal(newTokens[back].norm, "flour");
  assert.ok(back > at);
});

test("finishing a script means it starts over next time", () => {
  const tokens = tokensOf(SCRIPT);
  const store = rememberPosition({}, tokens, tokens.length);
  assert.equal(restorePosition(store, tokens), 0);
});

test("going back to the top forgets the position", () => {
  const tokens = tokensOf(SCRIPT);
  const store = rememberPosition(rememberPosition({}, tokens, 20), tokens, 0);
  assert.deepEqual(store, {});
});

test("scripts are told apart by their opening words", () => {
  const a = tokensOf(SCRIPT);
  const b = tokensOf(
    "A completely different script about planting tomatoes in spring, with some more words.",
  );
  assert.notEqual(scriptKey(a), scriptKey(b));
  const store = rememberPosition({}, a, 20);
  assert.equal(restorePosition(store, b), 0);
});

test("only the 50 most recent scripts are kept", () => {
  let store = {};
  for (let n = 0; n < 60; n++) {
    store = rememberPosition(store, tokensOf(`Script number ${n} ${SCRIPT}`), 5, n);
  }
  assert.equal(Object.keys(store).length, 50);
  assert.equal(restorePosition(store, tokensOf(`Script number 59 ${SCRIPT}`)), 5);
  assert.equal(restorePosition(store, tokensOf(`Script number 0 ${SCRIPT}`)), 0);
});

test("a bad saved entry falls back to the top", () => {
  const tokens = tokensOf(SCRIPT);
  const store = { [scriptKey(tokens)]: { i: "x" } };
  assert.equal(restorePosition(store, tokens), 0);
});
