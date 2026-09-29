import { align, buildTokens, parseScript, tokenizeHeard } from "./align.js";
import { createDecimator, createRing, encodeWav, RATE, rms } from "./audio.js";
import { rememberPosition, restorePosition } from "./positions.js";
import { applySetting, CHANNEL, keyAction } from "./remote.js";

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
  camera: false,
  cam: "",
  cameraOpacity: 25,
};

function loadSettings() {
  try {
    return {
      ...DEFAULT_SETTINGS,
      ...JSON.parse(
        localStorage.getItem("followspot.settings") || localStorage.getItem("prompter.settings") || "{}",
      ),
    };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

const settings = loadSettings();
const channel = new BroadcastChannel(CHANNEL);

function saveSettings() {
  try {
    localStorage.setItem("followspot.settings", JSON.stringify(settings));
  } catch {}
}

function applySettings() {
  const root = document.documentElement.style;
  root.setProperty("--font-size", `${settings.fontSize}px`);
  root.setProperty("--column-width", `${settings.columnWidth}vw`);
  root.setProperty("--reading-line", `${settings.readingLine}%`);
  root.setProperty("--margin-top", `${settings.marginTop}vh`);
  root.setProperty("--margin-bottom", `${settings.marginBottom}vh`);
  root.setProperty("--camera-opacity", settings.cameraOpacity / 100);
  $("stage").classList.toggle("mirror", settings.mirror);
  $("camera-view").classList.toggle("mirror", settings.mirror);
  document.body.classList.toggle("hide-cues", !settings.showCues);
  document.body.classList.toggle("hide-line", !settings.showReadingLine);
  document.body.classList.toggle("camera-on", settings.camera);
  syncCamera();
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
  $("tb-camera").classList.toggle("on", settings.camera);
  $("tb-listen").textContent = listening ? "Pause" : "Listen";
}

// ---------- script ----------

let paragraphs = [];
let tokens = [];
let wordEls = [];
let paraStarts = []; // token index where each paragraph begins
let cursor = 0; // next unread token, confirmed by speech (or keys)
let display = 0; // what the screen shows; can coast ahead of cursor
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
  // A script you've read from before picks up where you left off.
  if (first) {
    const at = restorePosition(loadPositions(), tokens);
    if (at > 0) {
      moveTo(at);
      savedCursor = at;
      setStatus("Resumed where you left off · R starts over", "");
    }
  }
  channel.postMessage({ type: "script", text: md });
}

// ---------- remembered positions ----------

let savedCursor = 0;

function loadPositions() {
  try {
    return JSON.parse(localStorage.getItem("followspot.positions") || "{}");
  } catch {
    return {};
  }
}

// Checked once a second; written only when the confirmed place moved.
function savePosition() {
  if (!tokens.length || cursor === savedCursor) return;
  savedCursor = cursor;
  try {
    localStorage.setItem(
      "followspot.positions",
      JSON.stringify(rememberPosition(loadPositions(), tokens, cursor)),
    );
  } catch {}
}

let dropped = false; // a dropped file wins over current.md until reload

// ?script=name.md loads another file from public/ (the README demo uses
// demo.md). Plain file names only, so the param can't reach outside public/.
const requested = new URLSearchParams(location.search).get("script");
const scriptFile = /^[\w.-]+\.(md|txt)$/.test(requested ?? "") ? requested : "current.md";

async function fetchText(name) {
  try {
    const res = await fetch(`${name}?t=${Date.now()}`, { cache: "no-store" });
    return res.ok ? await res.text() : null;
  } catch {
    return null;
  }
}

async function fetchScript() {
  if (dropped) return;
  const text = await fetchText(scriptFile);
  if (text !== null) return loadText(text);
  if (scriptText === null) {
    // Nothing linked: last dropped script, else the demo, so a first run
    // shows something you can read aloud right away.
    const saved = safeGet("followspot.script") ?? safeGet("prompter.script");
    const fallback = saved ?? (await fetchText("demo.md"));
    if (fallback !== null) loadText(fallback);
    else $("drop").hidden = false;
  }
}

function safeGet(key) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
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
    const target =
      ($("stage").clientHeight * settings.readingLine) / 100 - (w.offsetTop + w.offsetHeight / 2);
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
  // Route through a muted gain to the output: some engines skip processing
  // nodes that nothing downstream is pulling from.
  const mute = audioCtx.createGain();
  mute.gain.value = 0;
  src.connect(node).connect(mute).connect(audioCtx.destination);
  await populateDevices("audioinput", "mic", settings.mic);
}

function stopAudio() {
  for (const track of stream?.getTracks() ?? []) track.stop();
  audioCtx?.close();
  stream = null;
  audioCtx = null;
  ring.clear();
}

// Device labels are only visible once the page has permission for that
// kind, so the pickers fill in after the first successful start.
async function populateDevices(kind, selectId, value) {
  const devices = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === kind);
  const sel = $(selectId);
  sel.textContent = "";
  sel.append(new Option("System default", ""));
  for (const d of devices) sel.append(new Option(d.label || d.deviceId.slice(0, 8), d.deviceId));
  sel.value = value;
}

// ---------- camera ----------

// Optional dim self-view behind the script. It's a separate video-only
// stream, so toggling it never interrupts listening. Calls are chained so
// a burst of applySettings() (dragging a slider) can't open two streams.
let camStream = null;
let camDevice = "";
let camQueue = Promise.resolve();

function syncCamera() {
  camQueue = camQueue.then(syncCameraNow);
}

async function syncCameraNow() {
  if (camStream && (!settings.camera || camDevice !== settings.cam)) {
    for (const track of camStream.getTracks()) track.stop();
    camStream = null;
    $("camera-view").srcObject = null;
  }
  if (!settings.camera || camStream) return;
  try {
    camDevice = settings.cam;
    camStream = await navigator.mediaDevices.getUserMedia({
      video: {
        deviceId: settings.cam ? { exact: settings.cam } : undefined,
        width: { ideal: 1280 },
        height: { ideal: 720 },
      },
    });
    $("camera-view").srcObject = camStream;
    await populateDevices("videoinput", "cam", settings.cam);
  } catch (err) {
    settings.camera = false;
    document.body.classList.remove("camera-on");
    saveSettings();
    syncToolbar();
    setStatus(`Camera error: ${err.message}`, "err");
  }
}

function toggleCamera() {
  settings.camera = !settings.camera;
  applySettings();
}

// The words just behind the cursor, in their original spelling. Whisper
// treats the prompt as preceding context, which nudges it toward the
// script's spelling of names ("GitHub", "Kubernetes") without inviting it to
// invent words you haven't said yet.
function contextPrompt() {
  if (!tokens.length || cursor === 0) return "";
  const endWord = tokens[Math.min(cursor, tokens.length) - 1].word;
  return wordEls
    .slice(Math.max(0, endWord - 30), endWord + 1)
    .map((el) => el.textContent)
    .join(" ");
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

// Back to the top. Also clears "Resumed where you left off" while paused.
function restart() {
  moveTo(0);
  if (!listening) setStatus("Paused", "");
}

function jumpParagraph(dir) {
  if (!paraStarts.length) return;
  const cur = Math.floor(display);
  if (dir > 0) moveTo(paraStarts.find((i) => i > cur) ?? tokens.length);
  else moveTo([...paraStarts].reverse().find((i) => i < cur - 1) ?? 0);
}

function jumpToWord(w) {
  const t = tokens.findIndex((tok) => tok.word >= w);
  moveTo(t < 0 ? tokens.length : t);
  // Audio from before the jump mustn't drag the cursor back.
  ring.clear();
}

async function changeSetting(key, value) {
  const oldMic = settings.mic;
  if (!applySetting(settings, DEFAULT_SETTINGS, key, value)) return;
  applySettings();
  await restartMicIfChanged(oldMic);
}

async function restartMicIfChanged(oldMic) {
  if (!listening || settings.mic === oldMic) return;
  stopAudio();
  try {
    await startAudio();
  } catch (err) {
    listening = false;
    setStatus(`Mic error: ${err.message}`, "err");
    syncToolbar();
  }
}

function toggleFullscreen() {
  // Rejects without a user gesture in this window (e.g. sent from the
  // control window); there's nothing useful to do about that.
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen().catch(() => {});
}

// What each shortcut does (keys are mapped in remote.js). The control
// window sends these same names.
const ACTIONS = {
  listen: toggleListening,
  restart: restart,
  wordNext: () => moveTo(Math.floor(display) + 1),
  wordPrev: () => moveTo(Math.floor(display) - 1),
  paraNext: () => jumpParagraph(1),
  paraPrev: () => jumpParagraph(-1),
  camera: toggleCamera,
  mirror: () => changeSetting("mirror", !settings.mirror),
  bigger: () => changeSetting("fontSize", settings.fontSize + 4),
  smaller: () => changeSetting("fontSize", settings.fontSize - 4),
  wider: () => changeSetting("columnWidth", settings.columnWidth + 4),
  narrower: () => changeSetting("columnWidth", settings.columnWidth - 4),
  hud: () => document.body.classList.toggle("hide-hud"),
  fullscreen: toggleFullscreen,
  settings: () => openSettings(),
};

document.addEventListener("keydown", (e) => {
  if ($("settings").open || e.target.tagName === "INPUT") return;
  const action = keyAction(e);
  if (!action) return;
  e.preventDefault();
  ACTIONS[action]();
});

async function openSettings() {
  // Fill the pickers now if this page may already see device names (it has
  // used the mic or camera before), not only after the next start.
  const devices = await navigator.mediaDevices.enumerateDevices().catch(() => []);
  if (devices.some((d) => d.kind === "audioinput" && d.label)) await populateDevices("audioinput", "mic", "");
  if (devices.some((d) => d.kind === "videoinput" && d.label)) await populateDevices("videoinput", "cam", "");
  for (const key of Object.keys(DEFAULT_SETTINGS)) {
    const el = $(key);
    if (!el) continue;
    if (el.type === "checkbox") el.checked = settings[key];
    else el.value = settings[key];
  }
  if (!$("mic").options.length) $("mic").append(new Option("Start listening once to list mics", ""));
  if (!$("cam").options.length) $("cam").append(new Option("Turn the camera on once to list cameras", ""));
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
  await restartMicIfChanged(oldMic);
});

// Click a word to jump back (or ahead) to it.
$("script").addEventListener("click", (e) => {
  const el = e.target.closest(".w");
  if (el) jumpToWord(Number(el.dataset.w));
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
$("toolbar").addEventListener("mouseenter", () => {
  overToolbar = true;
});
$("toolbar").addEventListener("mouseleave", () => {
  overToolbar = false;
});

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
$("tb-listen").addEventListener("click", (e) => {
  e.currentTarget.blur();
  toggleListening();
});
$("tb-restart").addEventListener("click", (e) => {
  e.currentTarget.blur();
  restart();
});
$("tb-mirror").addEventListener("click", (e) => {
  e.currentTarget.blur();
  settings.mirror = !settings.mirror;
  applySettings();
});
$("tb-camera").addEventListener("click", (e) => {
  e.currentTarget.blur();
  toggleCamera();
});
$("tb-fullscreen").addEventListener("click", (e) => {
  e.currentTarget.blur();
  toggleFullscreen();
});
$("tb-controls").addEventListener("click", (e) => {
  e.currentTarget.blur();
  window.open("control.html", "followspot-control", "popup,width=1000,height=800");
});
$("tb-settings").addEventListener("click", (e) => {
  e.currentTarget.blur();
  openSettings();
});

// Drag and drop a script file.
window.addEventListener("dragover", (e) => {
  e.preventDefault();
  document.body.classList.add("dragging");
});
window.addEventListener("dragleave", () => document.body.classList.remove("dragging"));
window.addEventListener("drop", async (e) => {
  e.preventDefault();
  document.body.classList.remove("dragging");
  const file = e.dataTransfer.files[0];
  if (!file) return;
  const text = await file.text();
  try {
    localStorage.setItem("followspot.script", text);
  } catch {}
  dropped = true;
  scriptText = null;
  loadText(text);
});

// ---------- control window ----------

// control.html can drive the prompter from another screen. This window stays
// the source of truth: it answers commands and publishes its state whenever
// something changed (checked every 100 ms, sent only on a difference).
let lastState = "";

function publish(force = false) {
  const state = {
    type: "state",
    settings,
    listening,
    status: $("status").textContent,
    statusCls: $("dot").className,
    heard: $("heard").textContent,
    latency: $("latency").textContent,
    hud: !document.body.classList.contains("hide-hud"),
    word: currentWord(),
    words: wordEls.length,
  };
  const json = JSON.stringify(state);
  if (!force && json === lastState) return;
  lastState = json;
  channel.postMessage(state);
}

channel.onmessage = ({ data: m }) => {
  if (m?.type === "hello") {
    if (scriptText !== null) channel.postMessage({ type: "script", text: scriptText });
    publish(true);
  } else if (m?.type === "action" && Object.hasOwn(ACTIONS, m.name)) ACTIONS[m.name]();
  else if (m?.type === "set") changeSetting(m.key, m.value);
  else if (m?.type === "jump" && Number.isInteger(m.word)) jumpToWord(m.word);
};

// ---------- boot ----------

applySettings();
await fetchScript();
setInterval(fetchScript, 2000); // picks up edits to the script file live
setInterval(tick, 250);
setInterval(publish, 100);
setInterval(savePosition, 1000);
window.addEventListener("pagehide", savePosition);
setInterval(() => {
  $("level").style.width = `${Math.min(100, level * 800)}%`;
}, 50);
requestAnimationFrame(frame);
