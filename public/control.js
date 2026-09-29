import { parseScript } from "./align.js";
import { appBridge, NEW_SCRIPT, scriptFileName } from "./native.js";
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
  if (m?.type === "script") {
    if (m.text === scriptText) return; // a resend after reconnecting
    renderScript(m.text);
    scriptArrived(m.text).catch(() => {});
  } else if (m?.type === "state") applyState(m);
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
  if (app && e.metaKey && e.key === "s") {
    e.preventDefault();
    saveScript();
    return;
  }
  if (["INPUT", "SELECT", "TEXTAREA"].includes(e.target.tagName)) return;
  const action = keyAction(e);
  // Fullscreen and the settings dialog only make sense in the prompter.
  if (!action || action === "fullscreen" || action === "settings") return;
  e.preventDefault();
  send({ type: "action", name: action });
});

// ---------- scripts (macOS app only) ----------

// The app lists the scripts folder, opens a script (the prompter reloads
// with it), and saves the editor's text to the open script's file. The
// prompter then picks the change up like any other edit to the file.
//
// Edits remember which file and which text they started from. Saving goes to
// that file even if the prompter has moved on, and the app refuses to
// overwrite it if it changed on disk in the meantime (another editor), unless
// you say so.
const app = appBridge();
let scriptText = null; // latest text the prompter is showing
let currentPath = null; // its file, or null for the demo or a dropped file
let editPath = null; // the file the editor's text belongs to
let baseText = null; // the text the current edits started from
let editing = false;
let dirty = false;
let newFor = "new"; // what the name form is for: "new" or "saveAs"

const baseName = (path) => path?.split("/").pop() ?? "this script";

function note(text, cls = "") {
  $("savestate").textContent = text;
  $("savestate").className = cls;
}

function setDirty(value) {
  dirty = value;
  if (dirty) note("Unsaved changes", "dirty");
}

async function call(type, args) {
  try {
    return await app(type, args);
  } catch (err) {
    note(err.message ?? String(err), "err");
    throw err;
  }
}

async function refreshScripts() {
  const { scripts, current, folderName } = await call("scripts.list");
  currentPath = current;
  const sel = $("scripts");
  sel.textContent = "";
  if (!current) sel.append(new Option("Demo or dropped script (not saved)", ""));
  for (const s of scripts) sel.append(new Option(s.name, s.path));
  if (!scripts.length) {
    const empty = new Option(`No scripts in ${folderName} yet: use New…`, "__none");
    empty.disabled = true;
    sel.append(empty);
  }
  sel.value = current ?? "";
}

function loadEditor(text) {
  $("editor").value = text;
  baseText = text;
  editPath = currentPath;
}

async function scriptArrived(text) {
  scriptText = text;
  if (!app) return;
  await refreshScripts().catch(() => {});
  if (!dirty) loadEditor(text);
  else if (currentPath === editPath && text !== baseText) {
    note("The file changed on disk too. Saving will ask before replacing it.", "dirty");
  }
}

function setEditing(on) {
  editing = on;
  $("edit").classList.toggle("on", on);
  $("save").hidden = !on;
  $("script").hidden = on;
  $("editor").hidden = !on;
  $("pane").classList.toggle("editing", on);
  if (on) {
    if (!dirty) loadEditor(scriptText ?? "");
    $("editor").focus();
  }
}

// True once saved. False if it needs a name first, or you kept the other
// version after a conflict.
async function saveScript(force = false) {
  if (!dirty && !force) return true;
  if (!editPath) {
    askName("saveAs");
    return false;
  }
  const text = $("editor").value;
  const result = await call("scripts.save", { text, base: baseText, path: editPath, force });
  if (result?.conflict) {
    const replace = confirm(
      `${baseName(editPath)} changed on disk since you started editing (in another editor?). ` +
        "Replace that version with yours?",
    );
    if (replace) return saveScript(true);
    note("Not saved. Copy your changes somewhere, then switch scripts to see the other version.", "err");
    return false;
  }
  baseText = text;
  setDirty(false);
  note(
    editPath === currentPath
      ? "Saved. The prompter updates in a moment."
      : `Saved ${baseName(editPath)} (the prompter is showing another script).`,
  );
  return true;
}

function askName(purpose) {
  newFor = purpose;
  $("newform").hidden = false;
  $("new").hidden = true;
  $("create").textContent = purpose === "saveAs" ? "Save" : "Create";
  $("newname").value = "";
  $("newname").focus();
}

function closeNameForm() {
  $("newform").hidden = true;
  $("new").hidden = false;
}

if (app) {
  // For the app: it asks before closing this window, quitting, or opening
  // another script while there are unsaved edits (PrompterWindow.swift).
  window.followspotEditor = {
    state: () => ({ dirty, name: editPath ? baseName(editPath) : "the new script" }),
    save: () => saveScript().catch(() => false),
  };
  $("scriptbar").hidden = false;
  $("edit").addEventListener("click", () => setEditing(!editing));
  $("save").addEventListener("click", () => saveScript().catch(() => {}));
  $("editor").addEventListener("input", () => setDirty(true));
  $("new").addEventListener("click", () => {
    if (dirty && !confirm("Discard unsaved changes to this script?")) return;
    askName("new");
  });
  $("newcancel").addEventListener("click", closeNameForm);
  $("reveal").addEventListener("click", () => call("scripts.reveal").catch(() => {}));
  $("scripts").addEventListener("focus", () => refreshScripts().catch(() => {}));
  $("scripts").addEventListener("change", async (e) => {
    const path = e.target.value;
    if (!path || path === currentPath) return;
    if (dirty && !confirm("Discard unsaved changes to this script?")) {
      e.target.value = currentPath ?? "";
      return;
    }
    setDirty(false);
    note("");
    await call("scripts.open", { path }).catch(() => {});
  });
  $("newform").addEventListener("submit", async (e) => {
    e.preventDefault();
    const name = scriptFileName($("newname").value);
    if (!name) return note("Use a plain name, like “Launch video”.", "err");
    const text = newFor === "saveAs" ? $("editor").value : NEW_SCRIPT;
    try {
      await call("scripts.create", { name, text });
    } catch {
      return;
    }
    closeNameForm();
    setDirty(false);
    note(`Created ${name}.`);
    $("editor").value = text;
    if (!editing) setEditing(true);
  });
  refreshScripts().catch(() => {});
}

// ---------- boot ----------

await listDevices();
send({ type: "hello" });
