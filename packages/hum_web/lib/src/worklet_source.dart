/// Registered `AudioWorkletProcessor` name used by `WebAudioOutputDriver`.
const String humWorkletProcessorName = 'hum-ring-buffer-processor';

/// Plain-JS `AudioWorkletProcessor` implementing a zero-allocation circular
/// ring buffer with `MessagePort` consumption credits for backpressure.
///
/// Embedded as a string so `hum_web` can load it via `Blob` + `URL.createObjectURL`
/// without requiring consumers to copy a `.js` file into `web/`.
const String humWorkletJsSource = r'''
class HumRingBufferProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const opts = (options && options.processorOptions) || {};
    this.numChannels = Math.max(1, opts.numChannels | 0);
    this.capacityFrames = Math.max(128, opts.bufferFrames | 0);
    this.buffer = new Float32Array(this.capacityFrames * this.numChannels);
    this.readFrame = 0;
    this.writeFrame = 0;
    this.availableFrames = 0;
    this.underruns = 0;
    this.running = true;

    this.port.onmessage = (event) => {
      const msg = event.data;
      if (!msg) return;

      if (msg.type === 'audio') {
        this._pushInterleaved(msg.data, msg.frames | 0);
      } else if (msg.type === 'reset') {
        this.readFrame = 0;
        this.writeFrame = 0;
        this.availableFrames = 0;
        this.underruns = 0;
      } else if (msg.type === 'stop') {
        this.running = false;
      }
    };
  }

  _pushInterleaved(data, frames) {
    if (!data || frames <= 0) return;
    const ch = this.numChannels;
    const cap = this.capacityFrames;
    const free = cap - this.availableFrames;
    const toWrite = frames < free ? frames : free;

    for (let f = 0; f < toWrite; f++) {
      const dstBase = this.writeFrame * ch;
      const srcBase = f * ch;
      for (let c = 0; c < ch; c++) {
        this.buffer[dstBase + c] = data[srcBase + c];
      }
      this.writeFrame++;
      if (this.writeFrame >= cap) this.writeFrame = 0;
    }

    this.availableFrames += toWrite;
  }

  process(inputs, outputs) {
    if (!this.running) return false;

    const output = outputs[0];
    if (!output || output.length === 0) return true;

    const frameCount = output[0].length;
    const outChannels = output.length;
    const ch = this.numChannels;
    const cap = this.capacityFrames;
    const toRead = this.availableFrames < frameCount ? this.availableFrames : frameCount;

    for (let f = 0; f < toRead; f++) {
      const srcBase = this.readFrame * ch;
      for (let c = 0; c < outChannels; c++) {
        output[c][f] = c < ch ? this.buffer[srcBase + c] : 0.0;
      }
      this.readFrame++;
      if (this.readFrame >= cap) this.readFrame = 0;
    }

    if (toRead < frameCount) {
      this.underruns++;
      for (let c = 0; c < outChannels; c++) {
        output[c].fill(0.0, toRead, frameCount);
      }
    }

    this.availableFrames -= toRead;

    if (toRead > 0) {
      this.port.postMessage({
        type: 'consumed',
        frames: toRead,
        underruns: this.underruns,
      });
    }

    return true;
  }
}

if (!globalThis.__humRingBufferRegistered) {
  globalThis.__humRingBufferRegistered = true;
  registerProcessor('hum-ring-buffer-processor', HumRingBufferProcessor);
}
''';

/// Registered `AudioWorkletProcessor` name used by `WebAudioInputDriver`.
const String humCaptureWorkletProcessorName = 'hum-capture-processor';

/// Plain-JS `AudioWorkletProcessor` that captures multi-channel audio blocks
/// from its input bus, interleaves them, and posts them to Dart over
/// `MessagePort`.
const String humCaptureWorkletJsSource = r'''
class HumCaptureProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const opts = (options && options.processorOptions) || {};
    this.numChannels = Math.max(1, opts.numChannels | 0);
    this.scratch = new Float32Array(128 * this.numChannels);
    this.running = true;

    this.port.onmessage = (event) => {
      const msg = event.data;
      if (msg && msg.type === 'stop') {
        this.running = false;
      }
    };
  }

  process(inputs) {
    if (!this.running) return false;

    const input = inputs[0];
    if (!input || input.length === 0) return true;

    const frameCount = input[0].length;
    if (frameCount === 0) return true;

    const ch = this.numChannels;
    const needed = frameCount * ch;
    if (this.scratch.length !== needed) {
      this.scratch = new Float32Array(needed);
    }

    const out = this.scratch;
    for (let f = 0; f < frameCount; f++) {
      const dstBase = f * ch;
      for (let c = 0; c < ch; c++) {
        out[dstBase + c] = c < input.length ? input[c][f] : 0.0;
      }
    }

    this.port.postMessage({
      type: 'audio',
      data: out,
      frames: frameCount,
    });

    return true;
  }
}

if (!globalThis.__humCaptureRegistered) {
  globalThis.__humCaptureRegistered = true;
  registerProcessor('hum-capture-processor', HumCaptureProcessor);
}
''';
