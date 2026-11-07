import 'dart:io';

import 'package:hum/hum.dart';

/// Demonstrates the [Chance] node (Bernoulli Gate).
///
/// A 16th-note clock generates steady trigger impulses at 130 BPM.
/// The [Chance] node routes these impulses probabilistically:
/// - **Voice A (70% probability):** A crisp, tight closed hi-hat / click (short 40ms decay, panned left).
/// - **Voice B (30% probability):** A resonant electronic cowbell / bell accent (longer 200ms decay, panned right).
///
/// Listen to how a completely uniform clock is transformed into an organic,
/// lively rhythmic counterpoint.
void main() {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(130);

  // Render 4 bars of groove
  final totalBlocks = tempo.blocksFor(bars: 4, sampleRate: sr, vectorSize: vs);
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);

  // 1. Master clock running at steady 16th notes
  final clock = Clock(
    frequency: .value(1 / tempo.sixteenth),
    pulseWidth: const .value(0.5),
  );

  // 2. Chance (Bernoulli Gate): 70% chance to A, 30% chance to B
  final router = Chance(
    input: clock.trigger,
    probability: const .value(0.70),
    seed: 42, // Seeded for consistent demo output
  );

  // 3. Voice A (Closed Hat): High-frequency triangle ping with snappy 40ms decay
  final hatEnv = Decay.pure(
    trigger: router.a,
    time: const .value(0.04),
    curve: .exponential,
  );
  final hatOsc = TriangleOscillator(frequency: const .value(2400.0));
  final hatVoice = Mult.mono(
    value: .signal(hatEnv.outlet),
    input: hatOsc.outlet,
  );
  final hatPanned = StereoPan(
    input: hatVoice.outlet,
    pan: const .value(-0.5), // Panned left
  );

  // 4. Voice B (Resonant Cowbell / Bell): Dual-tone with medium 200ms decay
  final bellEnv = Decay.pure(
    trigger: router.b,
    time: const .value(0.20),
    curve: .exponential,
  );
  final bellOsc1 = SquareOscillator(frequency: const .value(587.33)); // D5
  final bellOsc2 = SineOscillator(frequency: const .value(880.0)); // A5
  final bellMix = bellOsc1.outlet + bellOsc2.outlet;
  final bellVoice = Mult.mono(
    value: .signal(bellEnv.outlet),
    input: bellMix,
  );
  final bellPanned = StereoPan(
    input: bellVoice.outlet,
    pan: const .value(0.5), // Panned right
  );

  // 5. Stereo Master Sum (mix both panned voices)
  final masterLeft = hatPanned.left + bellPanned.left;
  final masterRight = hatPanned.right + bellPanned.right;

  // Scale down master slightly to prevent clipping
  final masterScaled = Mult.stereo(
    value: const .value(0.5),
    leftInput: masterLeft,
    rightInput: masterRight,
  );

  // 6. Connect to WAV file sink
  Directory('tmp').createSync(recursive: true);
  const outPath = 'tmp/chance_demo.wav';
  final wav = WavSink.file(
    channels: masterScaled.outlets,
    path: outPath,
  );

  final pipeline = compilePipeline(root: wav, context: context).pipeline!;
  print('Rendering 4 bars of Chance (Bernoulli Gate) demo at 130 BPM...');
  for (int b = 0; b < totalBlocks; b++) {
    pipeline.process();
  }
  pipeline.processorOf(wav).close();

  print('Rendered demo successfully to $outPath');
}
