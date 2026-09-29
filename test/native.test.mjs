import assert from "node:assert/strict";
import { test } from "node:test";
import { parseScript } from "../public/align.js";
import { appBridge, NEW_SCRIPT, scriptFileName } from "../public/native.js";

test("appBridge is null outside the app", () => {
  assert.equal(appBridge({}), null);
  assert.equal(appBridge({ webkit: { messageHandlers: {} } }), null);
});

test("appBridge sends type and args to the app's handler", async () => {
  const sent = [];
  const postMessage = async (m) => {
    sent.push(m);
    return "ok";
  };
  const call = appBridge({ webkit: { messageHandlers: { followspot: { postMessage } } } });
  assert.equal(await call("scripts.save", { text: "hi" }), "ok");
  assert.deepEqual(sent, [{ type: "scripts.save", text: "hi" }]);
});

test("scriptFileName adds .md and keeps .md/.txt", () => {
  assert.equal(scriptFileName("  Launch video "), "Launch video.md");
  assert.equal(scriptFileName("notes.txt"), "notes.txt");
  assert.equal(scriptFileName("Intro.MD"), "Intro.MD");
  assert.equal(scriptFileName("v1.2 take"), "v1.2 take.md");
});

test("scriptFileName refuses empty, hidden, and path-like names", () => {
  for (const bad of ["", "   ", ".secret", "../up", "a/b", "a:b", "a\\b", null, undefined]) {
    assert.equal(scriptFileName(bad), null, String(bad));
  }
});

test("a new script's only readable part is the placeholder paragraph", () => {
  const paras = parseScript(NEW_SCRIPT);
  assert.equal(paras.length, 1);
  assert.match(paras[0].map((i) => i.text).join(" "), /^Your script goes here/);
});
