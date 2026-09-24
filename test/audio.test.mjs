import { test } from "node:test";
import assert from "node:assert/strict";
import { createDecimator, createRing, encodeWav, rms } from "../public/audio.js";

test("decimator turns 48 kHz into 16 kHz, one output per three inputs", () => {
  const out = [];
  const dec = createDecimator(48000);
  dec(new Float32Array(4800).fill(0.5), (x) => out.push(x));
  assert.equal(out.length, 1600);
  assert.ok(out.every((x) => Math.abs(x - 0.5) < 1e-6));
});

test("decimator carries fractional phase across blocks (44.1 kHz)", () => {
  const out = [];
  const dec = createDecimator(44100);
  for (let i = 0; i < 100; i++) dec(new Float32Array(441), (x) => out.push(x));
  // 44,100 input samples is one second: expect 16,000 outputs, give or take one.
  assert.ok(Math.abs(out.length - 16000) <= 1, `got ${out.length}`);
});

test("decimator averages, which filters out high-frequency alternation", () => {
  const out = [];
  const dec = createDecimator(32000);
  const block = Float32Array.from({ length: 64 }, (_, i) => (i % 2 ? 1 : -1));
  dec(block, (x) => out.push(x));
  assert.ok(out.every((x) => Math.abs(x) < 1e-6));
});

test("ring returns the most recent samples in order and wraps", () => {
  const ring = createRing(1, 10); // 10 slots
  for (let i = 0; i < 25; i++) ring.push(i);
  assert.equal(ring.size, 10);
  assert.deepEqual([...ring.last(0.5)], [20, 21, 22, 23, 24]);
  assert.deepEqual([...ring.last(5)], [15, 16, 17, 18, 19, 20, 21, 22, 23, 24]);
  ring.clear();
  assert.equal(ring.last(1).length, 0);
});

test("rms of silence is zero and of a constant is its magnitude", () => {
  assert.equal(rms(new Float32Array(0)), 0);
  assert.equal(rms(new Float32Array(100)), 0);
  assert.ok(Math.abs(rms(new Float32Array(100).fill(-0.25)) - 0.25) < 1e-6);
});

test("encodeWav writes a valid 16 kHz mono 16-bit header and clamps samples", () => {
  const bytes = encodeWav(Float32Array.from([0, 1, -1, 2, -2]));
  const v = new DataView(bytes.buffer);
  const ascii = (o) => String.fromCharCode(...bytes.slice(o, o + 4));
  assert.equal(ascii(0), "RIFF");
  assert.equal(ascii(8), "WAVE");
  assert.equal(ascii(36), "data");
  assert.equal(v.getUint16(22, true), 1);      // mono
  assert.equal(v.getUint32(24, true), 16000);  // sample rate
  assert.equal(v.getUint16(34, true), 16);     // bits per sample
  assert.equal(v.getUint32(40, true), 10);     // 5 samples * 2 bytes
  assert.deepEqual(
    [0, 1, 2, 3, 4].map((i) => v.getInt16(44 + i * 2, true)),
    [0, 32767, -32768, 32767, -32768],
  );
});
