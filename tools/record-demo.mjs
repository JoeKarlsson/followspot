// Records docs/demo.gif: the real pipeline, no faked scrolling. macOS `say`
// reads public/demo.md into a WAV, the page's getUserMedia is swapped for a
// stream that plays that WAV (headless Chrome's --use-file-for-fake-audio-capture
// delivers silence on macOS), Followspot tracks it through the running whisper
// server, and screenshots are stitched into a GIF with ffmpeg.
//
//   ./followspot --no-open &            # any model; medium looks best
//   node tools/record-demo.mjs [--port 8178] [--out docs/demo.gif] [--seconds N]
//
// Needs macOS (say), Google Chrome, and ffmpeg.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseScript } from "../public/align.js";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const port = opt("port", "8178");
const out = resolve(opt("out", "docs/demo.gif"));
const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const WIDTH = 1280;
const HEIGHT = 720;
const FPS = 8;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

if (!existsSync(CHROME)) throw new Error(`Chrome not found at ${CHROME}; set CHROME=/path/to/chrome`);

// 1. Speech: the spoken words of the demo script, with a beat of silence
//    first so the recording opens on a still frame.
const dir = mkdtempSync(join(tmpdir(), "followspot-demo-"));
const words = parseScript(readFileSync("public/demo.md", "utf8"))
  .map((p) =>
    p
      .filter((i) => i.type === "word")
      .map((i) => i.text)
      .join(" "),
  )
  .filter(Boolean)
  .join(" [[slnc 500]] ");
execFileSync("say", ["-r", "165", "-o", join(dir, "s.aiff"), `[[slnc 1500]] ${words}`]);
const wav = join(dir, "s.wav");
execFileSync("ffmpeg", [
  "-loglevel",
  "error",
  "-y",
  "-i",
  join(dir, "s.aiff"),
  "-ar",
  "16000",
  "-ac",
  "1",
  "-c:a",
  "pcm_s16le",
  wav,
]);
const speechSec = Number(
  execFileSync("ffprobe", [
    "-v",
    "error",
    "-show_entries",
    "format=duration",
    "-of",
    "csv=p=0",
    wav,
  ]).toString(),
);
const seconds = Number(opt("seconds", Math.ceil(speechSec + 2.5)));

// 2. Headless Chrome. The microphone is replaced in-page (see fakeMic).
const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    `--remote-debugging-port=9333`,
    `--user-data-dir=${join(dir, "profile")}`,
    `--window-size=${WIDTH},${HEIGHT}`,
    "--autoplay-policy=no-user-gesture-required",
    "about:blank",
  ],
  { stdio: "ignore" },
);

// Runs before the page's own scripts: getUserMedia returns a live stream
// that plays the speech WAV once, starting when the app opens the "mic".
const fakeMic = `(() => {
  const b64 = ${JSON.stringify(readFileSync(wav).toString("base64"))};
  navigator.mediaDevices.getUserMedia = async () => {
    const ctx = new AudioContext();
    await ctx.resume();
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const src = ctx.createBufferSource();
    src.buffer = await ctx.decodeAudioData(bytes.buffer);
    const dest = ctx.createMediaStreamDestination();
    src.connect(dest);
    src.start();
    return dest.stream;
  };
  navigator.mediaDevices.enumerateDevices = async () => [];
})();`;

let ws;
try {
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    await sleep(200);
    try {
      const list = await (await fetch("http://127.0.0.1:9333/json/list")).json();
      target = list.find((t) => t.type === "page");
    } catch {}
  }
  if (!target) throw new Error("Chrome's debugging port never came up");

  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r, j) => {
    ws.onopen = r;
    ws.onerror = j;
  });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve: res, reject: rej } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
    }
  };
  const send = (method, params = {}) =>
    new Promise((res, rej) => {
      pending.set(++id, { resolve: res, reject: rej });
      ws.send(JSON.stringify({ id, method, params }));
    });

  // Demo-friendly settings, then load the demo script.
  const url = `http://127.0.0.1:${port}/?script=demo.md`;
  await send("Page.enable");
  await send("Page.addScriptToEvaluateOnNewDocument", { source: fakeMic });
  await send("Page.navigate", { url });
  await sleep(1000);
  await send("Runtime.evaluate", {
    expression: `localStorage.setItem("followspot.settings", JSON.stringify({
      fontSize: 46, columnWidth: 62, readingLine: 42, coast: 1.5 }))`,
  });
  await send("Page.navigate", { url });
  await sleep(1500);

  // Space starts listening; the fake mic starts playing when capture opens.
  for (const type of ["keyDown", "keyUp"]) {
    await send("Input.dispatchKeyEvent", {
      type,
      key: " ",
      code: "Space",
      windowsVirtualKeyCode: 32,
      text: type === "keyDown" ? " " : undefined,
    });
  }

  // 3. Capture frames at a steady rate.
  const frames = join(dir, "frames");
  mkdirSync(frames);
  const total = seconds * FPS;
  const start = Date.now();
  for (let f = 0; f < total; f++) {
    const { data } = await send("Page.captureScreenshot", { format: "png" });
    writeFileSync(join(frames, `${String(f).padStart(5, "0")}.png`), Buffer.from(data, "base64"));
    const wait = start + ((f + 1) * 1000) / FPS - Date.now();
    if (wait > 0) await sleep(wait);
  }
  if (Date.now() - start > seconds * 1000 * 1.2) {
    console.warn("Capture ran slower than real time; the GIF will play fast. Try a smaller window.");
  }

  // 4. Two-pass palette GIF: much sharper text than ffmpeg's default palette.
  mkdirSync(resolve(out, ".."), { recursive: true });
  const filters = `fps=${FPS},scale=800:-1:flags=lanczos`;
  execFileSync("ffmpeg", [
    "-loglevel",
    "error",
    "-y",
    "-framerate",
    String(FPS),
    "-i",
    join(frames, "%05d.png"),
    "-vf",
    `${filters},palettegen=max_colors=48:stats_mode=diff`,
    join(dir, "palette.png"),
  ]);
  execFileSync("ffmpeg", [
    "-loglevel",
    "error",
    "-y",
    "-framerate",
    String(FPS),
    "-i",
    join(frames, "%05d.png"),
    "-i",
    join(dir, "palette.png"),
    "-lavfi",
    `${filters} [x]; [x][1:v] paletteuse=dither=none:diff_mode=rectangle`,
    "-loop",
    "0",
    out,
  ]);
  console.log(`Wrote ${out} (${seconds}s, ${total} frames)`);
} finally {
  ws?.close();
  chrome.kill();
  await sleep(300);
  rmSync(dir, { recursive: true, force: true });
}
