import assert from "node:assert/strict";
import { test } from "node:test";
import { applySetting, keyAction } from "../public/remote.js";

const DEFAULTS = { fontSize: 64, mirror: false, mic: "", cameraOpacity: 25 };

test("keyAction maps shortcuts, either case", () => {
  assert.equal(keyAction({ key: " " }), "listen");
  assert.equal(keyAction({ key: "r" }), "restart");
  assert.equal(keyAction({ key: "Home" }), "restart");
  assert.equal(keyAction({ key: "C" }), "camera");
  assert.equal(keyAction({ key: "ArrowDown" }), "paraNext");
});

test("keyAction ignores unmapped keys and browser shortcuts", () => {
  assert.equal(keyAction({ key: "x" }), null);
  assert.equal(keyAction({ key: "toString" }), null);
  assert.equal(keyAction({ key: "r", metaKey: true }), null);
  assert.equal(keyAction({ key: "r", ctrlKey: true }), null);
});

test("applySetting clamps numbers to their range", () => {
  const s = { ...DEFAULTS };
  assert.equal(applySetting(s, DEFAULTS, "fontSize", 400), true);
  assert.equal(s.fontSize, 160);
  applySetting(s, DEFAULTS, "cameraOpacity", 0);
  assert.equal(s.cameraOpacity, 5);
});

test("applySetting refuses unknown keys, wrong types, and NaN", () => {
  const s = { ...DEFAULTS };
  assert.equal(applySetting(s, DEFAULTS, "nope", 1), false);
  assert.equal(applySetting(s, DEFAULTS, "mirror", "yes"), false);
  assert.equal(applySetting(s, DEFAULTS, "fontSize", "72"), false);
  assert.equal(applySetting(s, DEFAULTS, "fontSize", Number.NaN), false);
  assert.deepEqual(s, DEFAULTS);
});

test("applySetting accepts booleans and strings as-is", () => {
  const s = { ...DEFAULTS };
  applySetting(s, DEFAULTS, "mirror", true);
  applySetting(s, DEFAULTS, "mic", "abc123");
  assert.equal(s.mirror, true);
  assert.equal(s.mic, "abc123");
});
