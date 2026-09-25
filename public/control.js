import { parseScript } from "./align.js";
import { CHANNEL, keyAction, LIMITS } from "./remote.js";

// Remote control for the prompter, meant for a second screen. It holds no
// state of its own: every button and input sends a message (see remote.js)
// and the display is redrawn from what the prompter publishes back.

const $ = (id) => document.getElementById(id);
const channel = new BroadcastChannel(CHANNEL);
const send = (msg) => channel.postMessage(msg);

// ---------- script ----------

let words = [];
let current = -1;
let lastUserScroll = 0; // don't yank the view while you're looking around

function renderScript(text) {
  const root = $("script");
  root.textContent = "";
  words = [];
  for (const para of parseScript(text)) {
    const onlyCues = para.every((i) => i.type === "cue");
    const el = document.createElement(onlyCues ? "div" : "p");
    for (const item of para) {
      const span = document.createElement("span");
      if (item.type === "cue") {
        span.className = onlyCues ? "cue" : "cue inline";
        span.textContent = `[${item.text}]`;
        el.append(span);
      } else {
        span.className = "w";
        span.dataset.w = words.length;
        span.textContent = item.text;
        words.push(span);
        el.append(span, " ");
      }
    }
    root.append(el);
  }
  const at = current;
  current = -1;
  paint(at);
}

function paint(word) {
  if (word === current) return;
  current = word;
  for (let w = 0; w < words.length; w++) {
    words[w].classList.toggle("read", w < word);
    words[w].classList.toggle("now", w === word);
  }
  if (performance.now() - lastUserScroll > 3000) {
    words[Math.min(word, words.length - 1)]?.scrollIntoView({ block: "center", behavior: "smooth" });
  }
}

$("script").addEventListener("click", (e) => {
  const el = e.target.closest(".w");
  if (el) send({ type: "jump", word: Number(el.dataset.w) });
});
for (const type of ["wheel", "touchmove"]) {
  $("pane").addEventListener(type, () => {
    lastUserScroll = performance.now();
  });
}

// ---------- state from the prompter ----------

let lastSeen = 0;

function applyState(s) {
  lastSeen = performance.now();
  $("offline").hidden = true;
  $("status").textContent = s.status;
  $("dot").className = s.statusCls;
  $("heard").textContent = s.heard;
  $("latency").textContent = s.latency;
  $("listen").textContent = s.listening ? "Pause" : "Listen";
  $("hud").classList.toggle("on", s.hud);
  for (const el of document.querySelectorAll("[data-on]"))
    el.classList.toggle("on", s.settings[el.dataset.on]);
  for (const el of document.querySelectorAll("[data-key]")) {
    const value = s.settings[el.dataset.key];
    if (el.type === "checkbox") el.checked = value;
    else if (el !== document.activeElement) el.value = value;
    const out = el.nextElementSibling;
    if (out?.tagName === "OUTPUT") out.textContent = value;
  }
  paint(s.word);
}

channel.onmessage = ({ data: m }) => {
  if (m?.type === "script") renderScript(m.text);
  else if (m?.type === "state") applyState(m);
};

// If the prompter goes away (closed, reloading), say so and keep asking.
setInterval(() => {
  if (performance.now() - lastSeen < 2000) return;
  $("offline").hidden = false;
  $("status").textContent = "Not connected";
  $("dot").className = "err";
  send({ type: "hello" });
}, 1000);

// ---------- inputs ----------

for (const el of document.querySelectorAll("[data-action]")) {
  el.addEventListener("click", () => {
    el.blur();
    send({ type: "action", name: el.dataset.action });
  });
}

for (const el of document.querySelectorAll("input[data-key], select[data-key]")) {
  const key = el.dataset.key;
  if (el.type === "range") [el.min, el.max] = LIMITS[key];
  el.addEventListener(el.type === "range" ? "input" : "change", () => {
    let value = el.value;
    if (el.type === "checkbox") value = el.checked;
    else if (el.type === "range") value = Number(el.value);
    send({ type: "set", key, value });
  });
  // Let the prompter's echo update a range once you let go of it.
  if (el.type === "range") el.addEventListener("change", () => el.blur());
}

// Device labels show once this origin has mic/camera permission, which the
// prompter window grants; refresh whenever a picker is opened.
async function listDevices() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  for (const sel of document.querySelectorAll("select[data-kind]")) {
    const value = sel.value;
    sel.textContent = "";
    sel.append(new Option("System default", ""));
    for (const d of devices.filter((d) => d.kind === sel.dataset.kind)) {
      sel.append(new Option(d.label || d.deviceId.slice(0, 8), d.deviceId));
    }
    sel.value = value;
  }
}
for (const sel of document.querySelectorAll("select[data-kind]")) sel.addEventListener("focus", listDevices);
navigator.mediaDevices.addEventListener("devicechange", listDevices);

document.addEventListener("keydown", (e) => {
  if (["INPUT", "SELECT"].includes(e.target.tagName)) return;
  const action = keyAction(e);
  // Fullscreen and the settings dialog only make sense in the prompter.
  if (!action || action === "fullscreen" || action === "settings") return;
  e.preventDefault();
  send({ type: "action", name: action });
});

// ---------- boot ----------

await listDevices();
send({ type: "hello" });
