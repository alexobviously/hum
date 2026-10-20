import 'package:hum/hum.dart';

/// Demonstrates the [Chorus] stereo ensemble effect.
///
/// A classic mono sawtooth synth lead playing an arpeggio is transformed
/// by [Chorus.toStereo] into a massive, lush vintage 80s stereo pad/lead
/// (in the style of the Roland Juno-106 / Dimension D chorus).
void main() {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(120);

  // Render 4 bars of 80s chorus synth groove
  final blocks = tempo.blocksFor(bars: 4, sampleRate: sr, vectorSize: vs);
  final context = const ProcessContext(sampleRate: sr, vectorSize: vs);

  // 1. 16th-note clock
  final clock = Clock(
    frequency: .value(1 / tempo.sixteenth),
    pulseWidth: const .value(0.5),
  );

  // 2. 80s synthwave arpeggio melody (Am -> F -> C -> G)
  final pitchSeq = StepSequencer.notes(
    clock: clock.trigger,
    notes: [
      'A3', 'C4', 'E4', 'A4', // Am
      'F3', 'A3', 'C4', 'F4', // F
      'C4', 'E4', 'G4', 'C5', // C
      'G3', 'B3', 'D4', 'G4', // G
    ],
  );

  // 3. Raw mono sawtooth oscillator
  final saw = SawtoothOscillator(
    frequency: .signal(pitchSeq.outlet),
  );

  // 4. Amplitude envelope with snappy attack and musical decay
  final env = Adsr(
    gate: clock.gate,
    attack: const .value(0.008),
    decay: .value(tempo.sixteenth * 0.75),
    sustain: const .value(0.2),
    release: const .value(0.05),
    curve: .exponential,
  );

  // 5. 12dB lowpass filter
  final filter = SvfFilter(
    input: saw.outlet,
    cutoff: const .value(1800.0),
    resonance: const .value(1.4),
  );

  // VCA: Voice = Filtered Saw * Envelope
  final voice = Mult.mono(
    input: filter.lowpass,
    value: .signal(env.outlet),
  );

  // 6. Chorus (Mono to Stereo Spread):
  // 1.4 Hz LFO rate, 3.5ms modulation depth, 16ms base delay, 90-deg quadrature spread.
  final chorus = Chorus.toStereo(
    input: voice.outlet,
    rate: const .value(1.4),
    depth: const .value(0.0035),
    baseDelay: const .value(0.016),
    mix: const .value(0.5),
  );

  // 7. Master Gain scaling (keep resonant peaks within clean headroom)
  final master = Mult(
    channels: chorus.outlets,
    value: const .value(0.55),
  );

  // 8. WAV Sink
  final wav = WavSink.file(
    channels: master.outlets,
    path: 'tmp/chorus_demo.wav',
  );

  final pipeline = compilePipeline(
    root: wav,
    context: context,
  );

  print('Rendering 4 bars of 80s chorus synth demo at 120 BPM...');
  for (int i = 0; i < blocks; i++) {
    pipeline.process();
  }

  pipeline.processorOf(wav).close();
  print('Saved demo to tmp/chorus_demo.wav');
}
