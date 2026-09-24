// End-to-end check without a microphone: macOS `say` reads the script,
// then the audio is replayed through the running whisper server in rolling
// windows, exactly like the browser loop, and the aligner's cursor is logged.
//
//   node tools/simulate.mjs path/to/script.md [--rate 170] [--port 8178] [--skip N]
//
// --skip N drops every Nth sentence from the reading, to check the prompter
// recovers when you skip or ad-lib.
//
// Fixtures (no `say` needed, so this runs on Linux too):
//   --save-audio f.wav   synthesize, write f.wav + f.json (the spoken text), exit
//   --audio f.wav        replay f.wav instead of synthesizing; refuses to run
//                        if f.json no longer matches the script (stale fixture)
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { align, buildTokens, parseScript, tokenizeHeard } from "../public/align.js";
import { encodeWav, RATE } from "../public/audio.js";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const file = args.find((a, i) => !a.startsWith("--") && !args[i - 1]?.startsWith("--"));
if (!file) {
  console.error(
    "usage: node tools/simulate.mjs script.md [--rate 170] [--port 8178] [--skip N] [--step 0.5] [--audio f.wav | --save-audio f.wav]",
  );
  process.exit(1);
}
const WINDOW = Number(opt("window", 3.5));
const STEP = Number(opt("step", 0.5)); // seconds between windows; the browser uses 0.25
const port = opt("port", "8178");
const skip = Number(opt("skip", 0));

const paragraphs = parseScript(readFileSync(file, "utf8"));
const tokens = buildTokens(paragraphs);
const words = paragraphs
  .flat()
  .filter((i) => i.type === "word")
  .map((i) => i.text);

let spoken = words.join(" ");
if (skip) {
  // Never drop the final sentence: the pass condition is reaching the end.
  const sentences = spoken.split(/(?<=[.?!])\s+/);
  spoken = sentences.filter((_, i) => (i + 1) % skip !== 0 || i === sentences.length - 1).join(" ");
}

// Minimal WAV reader: find the data chunk, read 16-bit mono PCM.
function readWav(path) {
  const buf = readFileSync(path);
  let off = 12;
  while (buf.toString("ascii", off, off + 4) !== "data") off += 8 + buf.readUInt32LE(off + 4);
  const int16 = new Int16Array(buf.buffer, buf.byteOffset + off + 8, buf.readUInt32LE(off + 4) / 2);
  return Float32Array.from(int16, (s) => s / 0x8000);
}

const audioIn = opt("audio");
const audioOut = opt("save-audio");
const sidecar = (wav) => wav.replace(/\.wav$/, ".json");
const dir = mkdtempSync(join(tmpdir(), "followspot-sim-"));

// say + ffmpeg -> 16 kHz mono float samples.
function synthesize() {
  // Trailing pause: real speakers don't stop dead, and Whisper tends to drop
  // a word that's cut off at the very end of a clip.
  execFileSync("say", ["-r", opt("rate", "170"), "-o", join(dir, "s.aiff"), `${spoken} [[slnc 1000]]`]);
  execFileSync("ffmpeg", [
    "-loglevel",
    "error",
    "-y",
    "-i",
    join(dir, "s.aiff"),
    "-ar",
    String(RATE),
    "-ac",
    "1",
    "-c:a",
    "pcm_s16le",
    join(dir, "s.wav"),
  ]);
  return readWav(join(dir, "s.wav"));
}

let pcm = new Float32Array(0);
if (audioIn) {
  // A fixture is only valid for the exact words it was recorded from.
  const meta = JSON.parse(readFileSync(sidecar(audioIn), "utf8"));
  if (meta.spoken !== spoken) {
    console.error(`${audioIn} is stale: ${file} (skip ${skip}) no longer matches it. Run: npm run fixtures`);
    process.exit(3);
  }
  pcm = readWav(audioIn);
} else {
  // On fresh CI runners `say` sometimes writes an empty file (the speech
  // service isn't up yet), so retry before giving up with a clear message.
  for (let attempt = 1; attempt <= 3 && pcm.length < RATE; attempt++) {
    if (attempt > 1) {
      console.warn(`say produced no audio, retrying (${attempt}/3)`);
      execFileSync("sleep", ["2"]);
    }
    pcm = synthesize();
  }
  if (pcm.length < RATE) {
    console.error("say produced no audio after 3 attempts; is macOS speech synthesis available?");
    process.exit(2);
  }
}

if (audioOut) {
  writeFileSync(audioOut, encodeWav(pcm));
  writeFileSync(sidecar(audioOut), `${JSON.stringify({ script: file, skip, spoken }, null, 2)}\n`);
  console.log(`Wrote ${audioOut} (${(pcm.length / RATE).toFixed(1)}s) and ${sidecar(audioOut)}`);
  process.exit(0);
}

let cursor = 0;
let moves = 0;
let misses = 0;
const latencies = [];
const duration = pcm.length / RATE;
const ordinal = (n) => {
  const teen = n % 100 >= 11 && n % 100 <= 13;
  return `${n}${teen ? "th" : ({ 1: "st", 2: "nd", 3: "rd" }[n % 10] ?? "th")}`;
};
console.log(
  `${tokens.length} tokens, ${duration.toFixed(1)}s of audio${skip ? `, skipping every ${ordinal(skip)} sentence` : ""}\n`,
);

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
  const t0 = performance.now();
  const res = await fetch(`http://127.0.0.1:${port}/inference`, { method: "POST", body: form });
  const { text = "" } = await res.json();
  latencies.push(performance.now() - t0);
  const r = align(tokens, cursor, tokenizeHeard(text));
  if (r && (r.pos >= cursor || r.matches >= 4)) {
    if (r.pos !== cursor) moves++;
    cursor = r.pos;
  } else {
    misses++;
  }
  const at = cursor < tokens.length ? words[tokens[cursor].word] : "(end)";
  console.log(
    `${t.toFixed(1).padStart(5)}s  cursor ${String(cursor).padStart(3)}/${tokens.length}  next: ${at.padEnd(14)}  heard: ${text.trim().slice(-60)}`,
  );
}

const pct = Math.round((cursor / tokens.length) * 100);
// Whisper latency per window. The browser can only keep up if this stays
// well under its 250 ms tick plus the window length; it's also the first
// number to check when CI is slow.
const sorted = [...latencies].sort((a, b) => a - b);
const pctile = (p) => Math.round(sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]);
console.log(
  `\nWhisper latency per window: median ${pctile(0.5)} ms, p90 ${pctile(0.9)} ms, max ${pctile(1)} ms (${sorted.length} requests)`,
);
console.log(
  `Finished at ${cursor}/${tokens.length} tokens (${pct}%), ${moves} moves, ${misses} windows without a match.`,
);
process.exit(cursor >= tokens.length - 2 ? 0 : 1);
