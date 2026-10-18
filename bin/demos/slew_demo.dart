import 'dart:io';

import 'package:hum/hum.dart';

// thank u bot

/// A dedicated, musical demonstration of [Slew] / [Portamento] / [Lag].
///
/// Features an alternating 2-octave synth lead (A2 110 Hz <-> A4 440 Hz)
/// with articulated phrasing and headroom to clearly hear how slew shapes
/// note transitions without distortion or clipping.
///
/// The demo plays 4 distinct 4-second stages:
/// 1. **Stage 1 (0.0s - 4.0s)**: Slew = 0.0s (Instant staccato octave jumps, zero glide)
/// 2. **Stage 2 (4.0s - 8.0s)**: Slew = 0.08s (Snappy, classic synthesizer portamento)
/// 3. **Stage 3 (8.0s - 12.0s)**: Slew = 0.30s (Deep, dramatic siren-like sweeps)
/// 4. **Stage 4 (12.0s - 16.0s)**: Asymmetric Slew (0.35s slow rise glide, 0.0s instant snap fall)
void main() {
  const sr = 44100;
  const vs = 64;
  const stageDurationSeconds = 4.0;
  const numStages = 4;
  const totalDurationSeconds = stageDurationSeconds * numStages;
  final blocksPerStage = (stageDurationSeconds * sr / vs).round();
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);

  print('=== Hum Slew / Portamento Dedicated Demo ===');
  print('Duration: ${totalDurationSeconds}s (4 distinct 4-second stages)');
  print('Listening for: A2 (110 Hz) <-> A4 (440 Hz) alternating octave jumps');

  // 1. Note Clock: 2 notes per second (120 BPM quarter notes)
  // Gate stays high for 80% of the note (0.4s note, 0.1s space)
  final noteClock = Clock(
    frequency: const .value(2.0),
    pulseWidth: const .value(0.8),
  );

  // 2. Alternating pitch CV: 1.0 Hz square wave (changes every 0.5s, synchronized with note clock)
  final pitchLfo = SquareOscillator(
    frequency: const .value(1.0),
    usePolyBlep: false,
  );
  final cv = Scale(
    input: pitchLfo.outlet,
    inLow: const .value(-1.0),
    inHigh: const .value(1.0),
    outLow: const .value(0.0),
    outHigh: const .value(1.0),
  );

  // 3. Slew Node:
  // Operating on the 0.0 -> 1.0 CV signal.
  // Because step height is 1.0 unit, the slew time in seconds matches the glide duration exactly.
  final slew = Slew.mono(
    input: cv.outlet,
    time: const .value(0.0),
  );

  // 4. Pitch Scaling:
  // Maps 0.0 -> A2 (110 Hz) and 1.0 -> A4 (440 Hz)
  final pitch = Scale(
    input: slew.outlet,
    inLow: const .value(0.0),
    inHigh: const .value(1.0),
    outLow: .value(Note.parse('A2').hz),
    outHigh: .value(Note.parse('A4').hz),
  );

  // 5. Synth Voice:
  // Warm sawtooth oscillator through a 1200 Hz resonant lowpass filter.
  final saw = SawtoothOscillator(
    frequency: .signal(pitch.outlet),
  );
  final filter = SvfFilter(
    input: saw.outlet,
    cutoff: const .value(1200.0),
    resonance: const .value(1.2),
  );

  // 6. Amplitude Envelope:
  // Smooth attack, sustained body, and clean release for articulated notes.
  final env = Adsr(
    gate: noteClock.gate,
    attack: const .value(0.01),
    decay: const .value(0.15),
    sustain: const .value(0.7),
    release: const .value(0.08),
    curve: .exponential,
  );
  final voiced = Mult.mono(
    value: ControlParam.signal(env.outlet),
    input: filter.lowpass,
  );

  // 7. Master Gain:
  // Scaled to 0.35 to guarantee clean headroom and zero clipping.
  final master = Mult.mono(
    value: const .value(0.35),
    input: voiced.outlet,
  );

  // Subtle rhythmic stereo delay
  final delay = Delay.mono(
    input: master.outlet,
    time: const .value(0.25),
    feedback: const .value(0.3),
    mix: const .value(0.25),
  );

  const outputPath = 'tmp/slew_demo.wav';
  final wav = WavSink.file(
    channels: [master.outlet, delay.outlet],
    path: outputPath,
  );

  final pipeline = compilePipeline(root: wav, context: context);
  final stopwatch = Stopwatch()..start();

  final stages = [
    (
      name: 'Stage 1: Zero Slew (0.0s)',
      desc: 'Instant stepped octave jumps. Sharp, robotic, zero glide.',
      rise: 0.0,
      fall: 0.0,
    ),
    (
      name: 'Stage 2: Snappy Portamento (0.08s)',
      desc: 'Classic synthesizer glide. Smooth, rubbery transitions.',
      rise: 0.08,
      fall: 0.08,
    ),
    (
      name: 'Stage 3: Deep Portamento (0.30s)',
      desc: 'Dramatic, swooping pitch glides across the 2-octave jump.',
      rise: 0.30,
      fall: 0.30,
    ),
    (
      name: 'Stage 4: Asymmetric Slew (rise: 0.35s, fall: 0.0s)',
      desc: 'Glides slowly UP into A4, but snaps instantly DOWN to A2.',
      rise: 0.35,
      fall: 0.0,
    ),
  ];

  for (int s = 0; s < stages.length; s++) {
    final stage = stages[s];
    print('\n[${s * 4}s - ${(s + 1) * 4}s] ${stage.name}');
    print('  ${stage.desc}');

    // Update slew parameters dynamically for this stage
    pipeline.update(
      slew,
      Slew.mono(
        input: cv.outlet,
        rise: .value(stage.rise),
        fall: .value(stage.fall),
      ),
    );

    for (int b = 0; b < blocksPerStage; b++) {
      pipeline.process();
    }
  }

  pipeline.processorOf(wav).close();
  stopwatch.stop();

  final file = File(outputPath);
  final sizeKb = (file.lengthSync() / 1024).toStringAsFixed(1);
  final renderMs = stopwatch.elapsedMilliseconds;
  final realtimeMultiple =
      (totalDurationSeconds * 1000 / (renderMs > 0 ? renderMs : 1))
          .toStringAsFixed(1);

  print('\n=== Render Complete ===');
  print(
    'Rendered in ${renderMs}ms (~${realtimeMultiple}x faster than real-time)',
  );
  print('Saved stereo audio to: $outputPath ($sizeKb KB)');
}
