// Forwards raw mic samples (already resampled to the context's 16 kHz rate)
// to the main thread in ~128-sample blocks.
// The node's (silent) output feeds a muted gain in app.js so the graph pulls it.
class Recorder extends AudioWorkletProcessor {
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (ch) this.port.postMessage(ch.slice(0));
    return true;
  }
}
registerProcessor("recorder", Recorder);
