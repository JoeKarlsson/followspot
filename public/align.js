// Script parsing + speech-to-script alignment. Pure functions, no DOM, so
// they run in the browser and under `node --test`.

const ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
  "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
  "eighteen", "nineteen"];
const TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];

// Whisper writes "30", scripts say "thirty". Spell digits out on both sides.
export function numToWords(n) {
  if (n < 20) return [ONES[n]];
  if (n < 100) return n % 10 ? [TENS[Math.floor(n / 10)], ONES[n % 10]] : [TENS[n / 10]];
  if (n < 1000) {
    const rest = n % 100 ? numToWords(n % 100) : [];
    return [ONES[Math.floor(n / 100)], "hundred", ...rest];
  }
  if (n < 10000) {
    const rest = n % 1000 ? numToWords(n % 1000) : [];
    return [...numToWords(Math.floor(n / 1000)), "thousand", ...rest];
  }
  return [String(n)];
}

// One raw chunk of text -> zero or more normalized match tokens.
export function normalize(chunk) {
  const out = [];
  const cleaned = chunk.toLowerCase().replace(/[’‘]/g, "'");
  for (const part of cleaned.split(/[-–/]+/)) {
    const w = part.replace(/'/g, "").replace(/[^a-z0-9]/g, "");
    if (!w) continue;
    if (/^\d+$/.test(w)) out.push(...numToWords(parseInt(w, 10)));
    else out.push(w);
  }
  return out;
}

// Transcript text -> tokens. Drops Whisper's non-speech markers like
// [BLANK_AUDIO] or (music).
export function tokenizeHeard(text) {
  const stripped = text.replace(/\[[^\]]*\]|\([^)]*\)|\*[^*]*\*/g, " ");
  return stripped.split(/\s+/).flatMap(normalize);
}

// Markdown -> paragraphs of display items.
//   - If the file has `---` rules, only the section after the first rule and
//     before the next one is the script (the header/shot-list layout the
//     video-script-writer skill produces). Otherwise the whole file is.
//   - `*[...]*` and bare `[...]` are cues: shown dimmed, never listened for.
//   - Headings, `**Label:**` metadata lines, and blockquote markers are skipped.
export function parseScript(md) {
  const text = md.replace(/\r\n?/g, "\n");
  const sections = text.split(/\n-{3,}\s*\n/);
  const body = sections.length >= 3 ? sections[1] : text;

  const paragraphs = [];
  for (const block of body.split(/\n\s*\n/)) {
    const lines = block.split("\n")
      .map((l) => l.trim())
      .filter((l) => l && !/^#{1,6}\s/.test(l) && !/^\*\*[^*]+:\*\*/.test(l))
      .map((l) => l.replace(/^>\s?/, ""));
    if (!lines.length) continue;
    const joined = lines.join(" ");
    const items = [];
    const cueRe = /\*\[([^\]]*)\]\*|\[([^\]]*)\]/g;
    let last = 0;
    const pushWords = (s) => {
      for (const raw of s.replace(/\*\*|__/g, "").replace(/[*_`]/g, "").split(/\s+/)) {
        if (raw) items.push({ type: "word", text: raw });
      }
    };
    for (const m of joined.matchAll(cueRe)) {
      pushWords(joined.slice(last, m.index));
      items.push({ type: "cue", text: (m[1] ?? m[2]).trim() });
      last = m.index + m[0].length;
    }
    pushWords(joined.slice(last));
    if (items.length) paragraphs.push(items);
  }
  return paragraphs;
}

// Flatten paragraphs into the token stream the aligner walks. Each token
// points back at the display word it came from.
export function buildTokens(paragraphs) {
  const tokens = [];
  let wordIndex = 0;
  for (const para of paragraphs) {
    for (const item of para) {
      if (item.type !== "word") continue;
      for (const norm of normalize(item.text)) tokens.push({ norm, word: wordIndex });
      wordIndex++;
    }
  }
  return tokens;
}

function levenshtein(a, b) {
  if (a === b) return 0;
  const prev = new Array(b.length + 1);
  for (let j = 0; j <= b.length; j++) prev[j] = j;
  for (let i = 1; i <= a.length; i++) {
    let diag = prev[0];
    prev[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = prev[j];
      prev[j] = Math.min(prev[j] + 1, prev[j - 1] + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1));
      diag = tmp;
    }
  }
  return prev[b.length];
}

const STOP = new Set(["the", "a", "an", "and", "to", "of", "it", "is", "in", "on", "you",
  "i", "that", "this", "so", "your", "for", "with", "its", "be", "or", "at", "but"]);

// How much a script word and a heard word agree. 0 = no match.
export function wordScore(s, h) {
  if (s === h) return STOP.has(s) ? 1 : 2;
  const min = Math.min(s.length, h.length);
  if (min < 4) return 0;
  if (s.startsWith(h) || h.startsWith(s)) return 1.5; // connector / connectors
  const d = levenshtein(s, h);
  if (d <= (min >= 7 ? 2 : 1)) return 1.5; // kubernetes / kubernetis, postgres / postgress
  return 0;
}

export const DEFAULTS = {
  back: 12,        // words behind the cursor to search (re-takes, repeats)
  ahead: 60,       // words ahead of the cursor to search
  maxHeard: 14,    // only align the newest N heard words
  minScore: 3.5,   // alignment must be at least this strong
  minMatches: 2,
  farJump: 20,     // jumps further than this need more evidence...
  farMatches: 4,   // ...this many matched words
  distPenalty: 0.04,
  backPenalty: 0.15,
};

// Smith-Waterman local alignment of the newest heard words against the
// script around the cursor. Returns the script token index just after the
// last matched word, or null when the evidence is too weak to move.
export function align(tokens, cursor, heard, opts = {}) {
  const o = { ...DEFAULTS, ...opts };
  const H = heard.slice(-o.maxHeard);
  const lo = Math.max(0, cursor - o.back);
  const hi = Math.min(tokens.length, cursor + o.ahead);
  const S = tokens.slice(lo, hi).map((t) => t.norm);
  if (!H.length || !S.length) return null;

  const GAP = -1;
  const MISS = -1;
  let prevScore = new Float64Array(S.length + 1);
  let prevMatch = new Int32Array(S.length + 1);
  let best = null;

  for (let i = 1; i <= H.length; i++) {
    const curScore = new Float64Array(S.length + 1);
    const curMatch = new Int32Array(S.length + 1);
    for (let j = 1; j <= S.length; j++) {
      const ws = wordScore(S[j - 1], H[i - 1]);
      const diag = prevScore[j - 1] + (ws > 0 ? ws : MISS);
      const up = prevScore[j] + GAP;
      const left = curScore[j - 1] + GAP;
      let score = 0;
      let matches = 0;
      if (diag > score) { score = diag; matches = prevMatch[j - 1] + (ws > 0 ? 1 : 0); }
      if (up > score) { score = up; matches = prevMatch[j]; }
      if (left > score) { score = left; matches = curMatch[j - 1]; }
      curScore[j] = score;
      curMatch[j] = matches;

      // Only cells that end on a match are valid landing spots.
      if (ws > 0 && score >= o.minScore && matches >= o.minMatches) {
        const pos = lo + j;
        const delta = pos - cursor;
        if (delta > o.farJump && matches < o.farMatches) continue;
        const adjusted = score - (delta >= 0 ? o.distPenalty * delta : o.backPenalty * -delta);
        if (!best || adjusted > best.adjusted) best = { pos, score, matches, adjusted };
      }
    }
    prevScore = curScore;
    prevMatch = curMatch;
  }
  return best;
}
