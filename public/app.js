import { align, buildTokens, parseScript, tokenizeHeard } from "./align.js";
import { RATE, createDecimator, createRing, encodeWav, rms } from "./audio.js";

const $ = (id) => document.getElementById(id);

// ---------- settings ----------

const DEFAULT_SETTINGS = {
  mic: "",
  fontSize: 64,
  columnWidth: 56,
  readingLine: 45,
  marginTop: 0,
  marginBottom: 0,
  windowSec: 3.5,
  gate: 0.012,
  coast: 1.5,
  mirror: false,
  showCues: true,
  showReadingLine: true,
};

function loadSettings() {
  try {
    return { ...DEFAULT_SETTINGS, ...JSON.parse(localStorage.getItem("prompter.settings") || "{}") };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

const settings = loadSettings();

function saveSettings() {
  try { localStorage.setItem("prompter.settings", JSON.stringify(settings)); } catch {}
}

function applySettings() {
  const root = document.documentElement.style;
  root.setProperty("--font-size", `${settings.fontSize}px`);
  root.setProperty("--column-width", `${settings.columnWidth}vw`);
  root.setProperty("--reading-line", `${settings.readingLine}%`);
  root.setProperty("--margin-top", `${settings.marginTop}vh`);
  root.setProperty("--margin-bottom", `${settings.marginBottom}vh`);
  $("stage").classList.toggle("mirror", settings.mirror);
  document.body.classList.toggle("hide-cues", !settings.showCues);
  document.body.classList.toggle("hide-line", !settings.showReadingLine);
  snap = true;
  syncToolbar();
  saveSettings();
}

function syncToolbar() {
  $("tb-fontSize").textContent = settings.fontSize;
  for (const el of document.querySelectorAll("#toolbar [data-setting]")) {
    el.value = settings[el.dataset.setting];
  }
  $("tb-mirror").classList.toggle("on", settings.mirror);
  $("tb-listen").textContent = listening ? "Pause" : "Listen";
}

// ---------- script ----------

let paragraphs = [];
let tokens = [];
let wordEls = [];
let paraStarts = []; // token index where each paragraph begins
let cursor = 0;      // next unread token, confirmed by speech (or keys)
let display = 0;     // what the screen shows; can coast ahead of cursor
let scriptText = null;

function render(md) {
  paragraphs = parseScript(md);
  tokens = buildTokens(paragraphs);
  const root = $("script");
  root.textContent = "";
  wordEls = [];
  paraStarts = [];

  for (const para of paragraphs) {
    const onlyCues = para.every((i) => i.type === "cue");
    const el = document.createElement(onlyCues ? "div" : "p");
    paraStarts.push(tokens.findIndex((t) => t.word >= wordEls.length));
    for (const item of para) {
      const span = document.createElement("span");
      if (item.type === "cue") {
        span.className = onlyCues ? "cue" : "cue inline";
        span.textContent = `[${item.text}]`;
        el.append(span);
      } else {
        span.className = "w";
        span.dataset.w = wordEls.length;
        span.textContent = item.text;
        wordEls.push(span);
        el.append(span, " ");
      }
    }
    root.append(el);
  }
  paraStarts = paraStarts.filter((i) => i >= 0);
  cursor = Math.min(cursor, tokens.length);
  display = cursor;
  snap = true;
  $("drop").hidden = true;
  paintWords(true);
}

function loadText(md) {
  if (md === scriptText) return;
  const first = scriptText === null;
  scriptText = md;
  if (first) cursor = 0;
  render(md);
}

let dropped = false; // a dropped file wins over current.md until reload

async function fetchScript() {
  if (dropped) return;
  try {
    const res = await fetch(`current.md?t=${Date.now()}`, { cache: "no-store" });
    if (res.ok) return loadText(await res.text());
  } catch {}
  if (scriptText === null) {
    const saved = safeGet("prompter.script");
    if (saved) loadText(saved);
    else $("drop").hidden = false;
  }
}

function safeGet(key) {
  try { return localStorage.getItem(key); } catch { return null; }
}

// ---------- display ----------

let lastNow = -1;
let lastRead = -1;

function currentWord() {
  if (!tokens.length) return 0;
  const i = Math.min(Math.floor(display), tokens.length - 1);
  return Math.floor(display) >= tokens.length ? wordEls.length : tokens[i].word;
}

function paintWords(force = false) {
  const now = currentWord();
  if (!force && now === lastNow) return;
  const from = force ? 0 : Math.min(lastRead, now);
  const to = force ? wordEls.length : Math.max(lastRead, now);
  for (let w = Math.max(0, from); w < Math.min(to + 1, wordEls.length); w++) {
    wordEls[w].classList.toggle("read", w < now);
    wordEls[w].classList.toggle("now", w === now);
  }
  lastNow = now;
  lastRead = now;
}

let scrollY = 0;
let snap = true; // jump straight to the target instead of easing (load, keys)

function frame(ts) {
  const dt = Math.min(0.1, (ts - (frame.last || ts)) / 1000);
  frame.last = ts;

  // Coast: while you're clearly talking but the matcher hasn't confirmed
  // anything for a moment, creep forward so the script never stalls. The
  // next confirmed match pulls it back into line.
  if (listening && settings.coast > 0 && speaking() && performance.now() - lastMatch > 1500) {
    display = Math.min(display + settings.coast * dt, cursor + 10, tokens.length);
  }
  if (display < cursor) display = cursor;

  paintWords();
  const w = wordEls[Math.min(currentWord(), wordEls.length - 1)];
  if (w) {
    // Center the current line on the reading line (your eye level at the lens).
    const target = ($("stage").clientHeight * settings.readingLine) / 100 - (w.offsetTop + w.offsetHeight / 2);
    scrollY = snap ? target : scrollY + (target - scrollY) * Math.min(1, dt * 6);
    snap = false;
    $("scroller").style.transform = `translate(-50%, ${scrollY}px)`;
  }
  requestAnimationFrame(frame);
}

// ---------- audio ----------

const ring = createRing(12);
let listening = false;
let audioCtx = null;
let stream = null;
let level = 0;
let lastLoud = 0;
let lastMatch = 0;

function speaking() {
  return performance.now() - lastLoud < 600;
}

async function startAudio() {
  const constraints = {
    audio: {
      deviceId: settings.mic ? { exact: settings.mic } : undefined,
      echoCancellation: false,
      noiseSuppression: true,
      autoGainControl: true,
      channelCount: 1,
    },
  };
  stream = await navigator.mediaDevices.getUserMedia(constraints);
  audioCtx = new AudioContext();
  await audioCtx.audioWorklet.addModule("recorder-worklet.js");
  const src = audioCtx.createMediaStreamSource(stream);
  const node = new AudioWorkletNode(audioCtx, "recorder");

  const decimate = createDecimator(audioCtx.sampleRate);
  node.port.onmessage = (e) => {
    const block = e.data;
    decimate(block, ring.push);
    const r = rms(block);
    level = level * 0.8 + r * 0.2;
    if (r > settings.gate) lastLoud = performance.now();
  };
  src.connect(node);
  await populateMics();
}

function stopAudio() {
  stream?.getTracks().forEach((t) => t.stop());
  audioCtx?.close();
  stream = null;
  audioCtx = null;
  ring.clear();
}

async function populateMics() {
  const devices = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === "audioinput");
  const sel = $("mic");
  sel.textContent = "";
  const def = new Option("System default", "");
  sel.append(def);
  for (const d of devices) sel.append(new Option(d.label || d.deviceId.slice(0, 8), d.deviceId));
  sel.value = settings.mic;
}

// The words just behind the cursor, in their original spelling. Whisper
// treats the prompt as preceding context, which nudges it toward the
// script's spelling of names ("GitHub", "Kubernetes") without inviting it to
// invent words you haven't said yet.
function contextPrompt() {
  if (!tokens.length || cursor === 0) return "";
  const endWord = tokens[Math.min(cursor, tokens.length) - 1].word;
  return wordEls.slice(Math.max(0, endWord - 30), endWord + 1).map((el) => el.textContent).join(" ");
}

// ---------- listen loop ----------

let inflight = false;

async function tick() {
  if (!listening || inflight || !tokens.length) return;
  if (rms(ring.last(0.8)) < settings.gate) {
    setStatus("Listening", "on");
    return;
  }
  const samples = ring.last(settings.windowSec);
  if (samples.length < RATE) return;

  inflight = true;
  const t0 = performance.now();
  setStatus("Listening", "busy");
  try {
    const form = new FormData();
    form.append("file", new Blob([encodeWav(samples)], { type: "audio/wav" }), "audio.wav");
    form.append("temperature", "0.0");
    form.append("response_format", "json");
    const prompt = contextPrompt();
    if (prompt) form.append("prompt", prompt);
    const res = await fetch("inference", { method: "POST", body: form });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const { text = "" } = await res.json();
    $("latency").textContent = `${Math.round(performance.now() - t0)} ms`;
    handleHeard(text.trim());
    setStatus("Listening", "on");
  } catch (err) {
    setStatus(`Can't reach whisper server (${err.message})`, "err");
  } finally {
    inflight = false;
  }
}

function handleHeard(text) {
  $("heard").textContent = text;
  const heard = tokenizeHeard(text);
  const r = align(tokens, cursor, heard);
  if (!r) return;
  // Forward moves need normal evidence; backing up (a re-take) needs more.
  if (r.pos >= cursor || r.matches >= 4) {
    cursor = r.pos;
    display = Math.max(cursor, Math.min(display, cursor + 1));
    lastMatch = performance.now();
  }
}

async function toggleListening() {
  if (listening) {
    listening = false;
    stopAudio();
    setStatus("Paused", "");
  } else {
    try {
      await startAudio();
      listening = true;
      lastMatch = performance.now();
      setStatus("Listening", "on");
    } catch (err) {
      setStatus(`Mic error: ${err.message}`, "err");
    }
  }
  syncToolbar();
}

function setStatus(text, cls) {
  $("status").textContent = text;
  $("dot").className = cls;
}

// ---------- controls ----------

function moveTo(tokenIndex) {
  cursor = Math.max(0, Math.min(tokens.length, tokenIndex));
  display = cursor;
  snap = true;
  lastMatch = performance.now();
}

function jumpParagraph(dir) {
  if (!paraStarts.length) return;
  const cur = Math.floor(display);
  if (dir > 0) moveTo(paraStarts.find((i) => i > cur) ?? tokens.length);
  else moveTo([...paraStarts].reverse().find((i) => i < cur - 1) ?? 0);
}

document.addEventListener("keydown", (e) => {
  if ($("settings").open || e.target.tagName === "INPUT") return;
  const k = e.key;
  if (k === " ") { e.preventDefault(); toggleListening(); }
  else if (k === "ArrowRight") moveTo(Math.floor(display) + 1);
  else if (k === "ArrowLeft") moveTo(Math.floor(display) - 1);
  else if (k === "ArrowDown") { e.preventDefault(); jumpParagraph(1); }
  else if (k === "ArrowUp") { e.preventDefault(); jumpParagraph(-1); }
  else if (k === "r" || k === "R") moveTo(0);
  else if (k === "m" || k === "M") { settings.mirror = !settings.mirror; applySettings(); }
  else if (k === "+" || k === "=") { settings.fontSize += 4; applySettings(); }
  else if (k === "-" || k === "_") { settings.fontSize = Math.max(20, settings.fontSize - 4); applySettings(); }
  else if (k === "]") { settings.columnWidth = Math.min(100, settings.columnWidth + 4); applySettings(); }
  else if (k === "[") { settings.columnWidth = Math.max(20, settings.columnWidth - 4); applySettings(); }
  else if (k === "h" || k === "H") document.body.classList.toggle("hide-hud");
  else if (k === "f" || k === "F") {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen();
  } else if (k === "s" || k === "S") openSettings();
});

function openSettings() {
  for (const key of Object.keys(DEFAULT_SETTINGS)) {
    const el = $(key);
    if (!el) continue;
    if (el.type === "checkbox") el.checked = settings[key];
    else el.value = settings[key];
  }
  if (!$("mic").options.length) $("mic").append(new Option("Start listening once to list mics", ""));
  $("settings").showModal();
}

$("settings").addEventListener("close", async () => {
  const oldMic = settings.mic;
  for (const key of Object.keys(DEFAULT_SETTINGS)) {
    const el = $(key);
    if (!el) continue;
    if (el.type === "checkbox") settings[key] = el.checked;
    else if (el.tagName === "SELECT") settings[key] = el.value;
    else if (el.value !== "") settings[key] = Number(el.value);
  }
  applySettings();
  if (listening && settings.mic !== oldMic) {
    stopAudio();
    await startAudio();
  }
});

// Click a word to jump back (or ahead) to it. The listen buffer is cleared
// so audio from before the jump can't drag the cursor back.
$("script").addEventListener("click", (e) => {
  const el = e.target.closest(".w");
  if (!el) return;
  const w = Number(el.dataset.w);
  const t = tokens.findIndex((tok) => tok.word >= w);
  moveTo(t < 0 ? tokens.length : t);
  ring.clear();
});

// Hover toolbar: show on mouse move, hide after a pause unless the pointer
// is over it or a slider is being dragged.
let hideTimer = 0;
let overToolbar = false;

function showToolbar() {
  document.body.classList.add("show-toolbar");
  document.body.classList.remove("idle");
  clearTimeout(hideTimer);
  hideTimer = setTimeout(() => {
    if (overToolbar) return showToolbar();
    document.body.classList.remove("show-toolbar");
    document.body.classList.add("idle");
  }, 2500);
}

window.addEventListener("mousemove", showToolbar);
$("toolbar").addEventListener("mouseenter", () => { overToolbar = true; });
$("toolbar").addEventListener("mouseleave", () => { overToolbar = false; });

for (const el of document.querySelectorAll("#toolbar [data-setting]")) {
  el.addEventListener("input", () => {
    settings[el.dataset.setting] = Number(el.value);
    applySettings();
  });
}
for (const el of document.querySelectorAll("#toolbar [data-step]")) {
  el.addEventListener("click", () => {
    const key = el.dataset.step;
    settings[key] = Math.max(20, Math.min(160, settings[key] + Number(el.dataset.by)));
    applySettings();
  });
}
$("tb-listen").addEventListener("click", (e) => { e.currentTarget.blur(); toggleListening(); });
$("tb-mirror").addEventListener("click", (e) => {
  e.currentTarget.blur();
  settings.mirror = !settings.mirror;
  applySettings();
});
$("tb-fullscreen").addEventListener("click", (e) => {
  e.currentTarget.blur();
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen();
});
$("tb-settings").addEventListener("click", (e) => { e.currentTarget.blur(); openSettings(); });

// Drag and drop a script file.
window.addEventListener("dragover", (e) => { e.preventDefault(); document.body.classList.add("dragging"); });
window.addEventListener("dragleave", () => document.body.classList.remove("dragging"));
window.addEventListener("drop", async (e) => {
  e.preventDefault();
  document.body.classList.remove("dragging");
  const file = e.dataTransfer.files[0];
  if (!file) return;
  const text = await file.text();
  try { localStorage.setItem("prompter.script", text); } catch {}
  dropped = true;
  scriptText = null;
  loadText(text);
});

// ---------- boot ----------

applySettings();
await fetchScript();
setInterval(fetchScript, 2000); // picks up edits to the script file live
setInterval(tick, 250);
setInterval(() => { $("level").style.width = `${Math.min(100, level * 800)}%`; }, 50);
requestAnimationFrame(frame);
