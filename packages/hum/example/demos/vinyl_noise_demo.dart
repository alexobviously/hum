import 'package:hum/hum.dart';

import '../harness.dart';

/// Lo-fi vinyl surface noise, crackle, and rotational warp emulation.
void main(List<String> args) => runDemo(
  name: 'vinyl_noise_demo',
  tempo: const Tempo(60),
  bars: 2,
  description: 'Vinyl crackle and warp on top of a Rhodes-like chord',
  args: args,
  builder: (context, tempo) {
    final chord = Note.parse('D3').maj9Chord;
    final oscs = [
      for (final f in chord.hz) SineOscillator(frequency: .value(f)),
    ];
    final oscOutlets = [for (final o in oscs) o.outlet];
    final chordMono = Sum(inputs: oscOutlets).outlet.mult(0.05).outlet;

    final chorus = Chorus(
      channels: [chordMono],
      outputsCount: 2,
      rate: const .value(0.4),
      depth: const .value(0.002),
      mix: const .value(0.4),
    );

    final saturated = Saturator.stereo(
      chorus.left,
      chorus.right,
      mode: .atan,
      drive: const .value(1.4),
      mix: const .value(1.0),
    );

    final vinyl = VinylNoise.rpm33(
      crackle: const .value(0.75),
      hiss: const .value(0.05),
      warp: const .value(0.25),
      density: const .value(60.0),
      seed: 42,
    );

    final reverb = Freeverb.stereo(
      left: saturated.left + vinyl.left,
      right: saturated.right + vinyl.right,
      roomSize: const .value(0.7),
      damp: const .value(0.5),
      mix: const .value(0.25),
    );

    return Out.stereo(left: reverb.left, right: reverb.right);
  },
);
