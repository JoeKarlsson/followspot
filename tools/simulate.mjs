// End-to-end check without a microphone: macOS `say` reads the script,
// then the audio is replayed through the running whisper server in rolling
// windows, exactly like the browser loop, and the aligner's cursor is logged.
//
//   node tools/simulate.mjs path/to/script.md [--rate 170] [--port 8178] [--skip N]
//
// --skip N drops every Nth sentence from the reading, to check the prompter
// recovers when you skip or ad-lib.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { align, buildTokens, parseScript, tokenizeHeard } from "../public/align.js";
import { RATE, encodeWav } from "../public/audio.js";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const file = args.find((a, i) => !a.startsWith("--") && !args[i - 1]?.startsWith("--"));
if (!file) {
  console.error("usage: node tools/simulate.mjs script.md [--rate 170] [--port 8178] [--skip N]");
  process.exit(1);
}
const WINDOW = Number(opt("window", 3.5));
const STEP = 0.5;
const port = opt("port", "8178");
const skip = Number(opt("skip", 0));

const paragraphs = parseScript(readFileSync(file, "utf8"));
const tokens = buildTokens(paragraphs);
const words = paragraphs.flat().filter((i) => i.type === "word").map((i) => i.text);

let spoken = words.join(" ");
if (skip) {
  // Never drop the final sentence: the pass condition is reaching the end.
  const sentences = spoken.split(/(?<=[.?!])\s+/);
  spoken = sentences.filter((_, i) => (i + 1) % skip !== 0 || i === sentences.length - 1).join(" ");
}

const dir = mkdtempSync(join(tmpdir(), "followspot-sim-"));
execFileSync("say", ["-r", opt("rate", "170"), "-o", join(dir, "s.aiff"), spoken]);
execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", join(dir, "s.aiff"),
  "-ar", String(RATE), "-ac", "1", "-c:a", "pcm_s16le", join(dir, "s.wav")]);

// Minimal WAV reader: find the data chunk, read 16-bit mono PCM.
const buf = readFileSync(join(dir, "s.wav"));
let off = 12;
while (buf.toString("ascii", off, off + 4) !== "data") off += 8 + buf.readUInt32LE(off + 4);
const int16 = new Int16Array(buf.buffer, buf.byteOffset + off + 8, buf.readUInt32LE(off + 4) / 2);
const pcm = Float32Array.from(int16, (s) => s / 0x8000);

let cursor = 0;
let moves = 0;
let misses = 0;
const duration = pcm.length / RATE;
console.log(`${tokens.length} tokens, ${duration.toFixed(1)}s of audio${skip ? `, skipping every ${skip}th sentence` : ""}\n`);

for (let t = 1.5; t <= duration + STEP; t += STEP) {
  const end = Math.min(pcm.length, Math.floor(t * RATE));
  const start = Math.max(0, end - Math.floor(WINDOW * RATE));
  const form = new FormData();
  form.append("file", new Blob([encodeWav(pcm.subarray(start, end))], { type: "audio/wav" }), "a.wav");
  form.append("temperature", "0.0");
  form.append("response_format", "json");
  if (cursor > 0) {
    const endWord = tokens[cursor - 1].word;
    form.append("prompt", words.slice(Math.max(0, endWord - 30), endWord + 1).join(" "));
  }
  const res = await fetch(`http://127.0.0.1:${port}/inference`, { method: "POST", body: form });
  const { text = "" } = await res.json();
  const r = align(tokens, cursor, tokenizeHeard(text));
  if (r && (r.pos >= cursor || r.matches >= 4)) {
    if (r.pos !== cursor) moves++;
    cursor = r.pos;
  } else {
    misses++;
  }
  const at = cursor < tokens.length ? words[tokens[cursor].word] : "(end)";
  console.log(`${t.toFixed(1).padStart(5)}s  cursor ${String(cursor).padStart(3)}/${tokens.length}  next: ${at.padEnd(14)}  heard: ${text.trim().slice(-60)}`);
}

const pct = Math.round((cursor / tokens.length) * 100);
console.log(`\nFinished at ${cursor}/${tokens.length} tokens (${pct}%), ${moves} moves, ${misses} windows without a match.`);
process.exit(cursor >= tokens.length - 2 ? 0 : 1);
