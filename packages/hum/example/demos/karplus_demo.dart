import 'package:hum/hum.dart';

import '../harness.dart';

/// Demonstrates Karplus-Strong plucked string physical modeling synthesis
/// processed through Bitcrusher and Freeverb.
void main(List<String> args) => runDemo(
  name: 'karplus_demo',
  tempo: const Tempo(140),
  bars: 8,
  description: 'Karplus-Strong plucked string physical modeling -> Bitcrusher -> Freeverb',
  args: args,
  builder: (context, tempo, _) {
    final clock = Clock.bpm(tempo.bpm);
    final note = Note.parse('C4');

    final lfo = SawtoothOscillator(frequency: .value(0.5 / tempo.bar)).outlet;
    final range1 = lfo.mapRange(0.3, 1.0).outlet;
    final range2 = lfo.mapRange(0.7, 0.0).outlet;

    final node = KarplusStrong(
      gate: clock.gate,
      frequency: .value(note.hz),
      feedback: const .value(0.997),
      pickHardness: .signal(range1),
      pickPosition: .signal(range1),
      damping: .signal(range2),
    );

    final bitcrusher = Bitcrusher.mono(
      input: node.outlet,
      downsample: const .value(4),
      bitDepth: const .value(6),
      mix: const .value(0.75),
    );

    final verb = Freeverb.mono(input: bitcrusher.outlet);

    return Out.stereo(left: verb.left, right: verb.right);
  },
);
