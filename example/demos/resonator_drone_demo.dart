import 'package:hum/hum.dart';

import '../harness.dart';

/// Demonstrates acoustic physical modeling drone synthesis using [ResonatorBank].
void main(List<String> args) => runDemo(
  name: 'resonator_drone_demo',
  tempo: const Tempo(60),
  bars: 2,
  description:
      'Ambient acoustic drone: brown noise -> ResonatorBank modal chord',
  args: args,
  builder: (context, tempo) {
    final noise = NoiseGenerator(type: .brown);

    final driftLfo = SineOscillator(
      frequency: const .value(0.1),
    ).mapRange(0.995, 1.005);

    // Am 9th modal chord
    final droneChord = [
      'A2', 'E3', 'A3', 'C4', //
      'E4', 'G4', 'B4', 'E5',
    ].map(Note.parse).toList();

    final resonator = ResonatorBank.chord(
      noise.outlet,
      notes: droneChord,
      q: const .value(45.0), // High Q produces long, bell-like sustain
      brightness: const .value(0.92), // High frequencies decay slightly faster
      spread: const .value(1.0), // Full stereo width
      frequencyMultiplier: .signal(driftLfo.outlet),
    );

    final saturated = Saturator.stereo(
      resonator.left,
      resonator.right,
      mode: .tanh,
      drive: const .value(1.8),
      mix: const .value(1.0),
      dcBlock: true,
    );

    final reverb = Freeverb.stereo(
      left: saturated.left,
      right: saturated.right,
      roomSize: const .value(0.85),
      damp: const .value(0.4),
      width: const .value(1.0),
      mix: const .value(0.45),
    );

    final leveled = Compressor.stereo(
      reverb.left,
      reverb.right,
      threshold: const .value(-12.0),
      ratio: const .value(2.5),
      attack: const .value(0.05),
      release: const .value(0.2),
      makeupGain: const .value(2.0),
    );

    return Out.stereo(left: leveled.left, right: leveled.right);
  },
);
