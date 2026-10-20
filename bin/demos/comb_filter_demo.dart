import 'package:hum/hum.dart';

/// Demonstrates physical acoustic modeling using the [CombFilter] node.
///
/// A 16th-note clock drives a [StepSequencer] through a minor pentatonic melody.
/// On each step, a tiny 8ms burst of white noise (a plectrum / hammer strike)
/// is fed into a tuned [CombFilter].
///
/// The comb filter's sub-sample fractional delay loop and 1-pole damping
/// transform the raw noise impulse into a warm, ringing acoustic plucked string
/// or marimba voice.
void main() {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(120);

  // Render 4 bars of physical modeling string melody
  final blocks = tempo.blocksFor(bars: 4, sampleRate: sr, vectorSize: vs);
  final context = const ProcessContext(sampleRate: sr, vectorSize: vs);

  // 1. Master clock at 16th notes
  final clock = Clock(
    frequency: .value(1 / tempo.sixteenth),
    pulseWidth: const .value(0.5),
  );

  // 2. Pentatonic pitch sequence (in Hz)
  // Notes: D3 (146.83), F3 (174.61), G3 (196.00), A3 (220.00), C4 (261.63), D4 (293.66)
  final pentatonicNotes = const [
    146.83,
    174.61,
    220.00,
    261.63,
    196.00,
    174.61,
    146.83,
    220.00,
    293.66,
    261.63,
    220.00,
    196.00,
    174.61,
    196.00,
    146.83,
    110.00,
  ];

  final pitchSeq = StepSequencer.fromList(
    clock: clock.trigger,
    steps: pentatonicNotes,
  );

  // 3. Noise burst exciter (simulating a plectrum pluck / hammer strike)
  final noise = NoiseGenerator.white();
  final strikeEnv = Decay.pure(
    trigger: clock.trigger,
    time: const .value(0.008), // Snappy 8ms burst of noise
    curve: .exponential,
  );
  final exciter = Mult.mono(
    input: noise.outlet,
    value: .signal(strikeEnv.outlet),
  );

  // 4. Tuned Resonant Comb Filter:
  // Converts the 8ms noise click into an acoustic plucked string tone.
  // High feedback (0.97) for ringing sustain, 1-pole damping (0.40) for warm woody decay.
  final combL = CombFilter.mono(
    input: exciter.outlet,
    frequency: .signal(pitchSeq.outlet),
    feedback: const .value(0.97),
    damp: const .value(0.40),
    mix: const .value(1.0),
  );

  // Right channel with slight pitch offset (+1.2 Hz) for stereo acoustic body width
  final pitchR = Add.mono(
    input: pitchSeq.outlet,
    value: const .value(1.2),
  );
  final combR = CombFilter.mono(
    input: exciter.outlet,
    frequency: .signal(pitchR.outlet),
    feedback: const .value(0.97),
    damp: const .value(0.45),
    mix: const .value(1.0),
  );

  // 5. Subtle Freeverb for acoustic room ambience
  final reverb = Freeverb.stereo(
    left: combL.outlet,
    right: combR.outlet,
    roomSize: const .value(0.60),
    damp: const .value(0.35),
    width: const .value(0.8),
    mix: const .value(0.25),
  );

  // 6. Master stereo output sink
  final wav = WavSink.file(
    channels: reverb.outlets,
    path: 'tmp/comb_filter_demo.wav',
  );

  final pipeline = compilePipeline(
    root: wav,
    context: context,
  );

  print('Rendering 4 bars of physical modeling string sequence at 120 BPM...');
  for (int i = 0; i < blocks; i++) {
    pipeline.process();
  }

  pipeline.processorOf(wav).close();
  print('Saved demo to tmp/comb_filter_demo.wav');
}
