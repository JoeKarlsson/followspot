// Audio helpers with no browser dependencies, so they're unit-testable.

export const RATE = 16000;

// Box-filter decimator: turns a stream of samples at `inRate` into 16 kHz by
// averaging each run of input samples that maps to one output sample. Cheap,
// and enough anti-aliasing for speech. Call it with successive blocks.
export function createDecimator(inRate, outRate = RATE) {
  const ratio = inRate / outRate;
  let acc = 0;
  let n = 0;
  let phase = 0;
  return (block, emit) => {
    for (const x of block) {
      acc += x;
      n++;
      phase += 1;
      if (phase >= ratio) {
        emit(acc / n);
        acc = 0;
        n = 0;
        phase -= ratio;
      }
    }
  };
}

// Fixed-size ring buffer of the most recent samples.
export function createRing(seconds, rate = RATE) {
  const buf = new Float32Array(Math.ceil(seconds * rate));
  let writePos = 0;
  let filled = 0;
  return {
    push(x) {
      buf[writePos] = x;
      writePos = (writePos + 1) % buf.length;
      if (filled < buf.length) filled++;
    },
    last(sec) {
      const n = Math.min(filled, Math.floor(sec * rate));
      const out = new Float32Array(n);
      const start = (writePos - n + buf.length) % buf.length;
      for (let i = 0; i < n; i++) out[i] = buf[(start + i) % buf.length];
      return out;
    },
    clear() {
      filled = 0;
    },
    get size() {
      return filled;
    },
  };
}

export function rms(samples) {
  let s = 0;
  for (const x of samples) s += x * x;
  return samples.length ? Math.sqrt(s / samples.length) : 0;
}

// Float samples in [-1, 1] -> 16-bit mono PCM WAV bytes.
export function encodeWav(samples, rate = RATE) {
  const buf = new ArrayBuffer(44 + samples.length * 2);
  const v = new DataView(buf);
  const str = (o, s) => {
    for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i));
  };
  str(0, "RIFF");
  v.setUint32(4, 36 + samples.length * 2, true);
  str(8, "WAVE");
  str(12, "fmt ");
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);
  v.setUint16(22, 1, true);
  v.setUint32(24, rate, true);
  v.setUint32(28, rate * 2, true);
  v.setUint16(32, 2, true);
  v.setUint16(34, 16, true);
  str(36, "data");
  v.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    v.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return new Uint8Array(buf);
}
