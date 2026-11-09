import 'package:hum/hum.dart';

import '../harness.dart';

/// Demonstrates Karplus-Strong plucked string physical modeling synthesis
/// processed through Bitcrusher and Freeverb.
void main(List<String> args) => runDemo(
  name: 'karplus_demo',
  tempo: const Tempo(140),
  bars: 4,
  description:
      'Karplus-Strong plucked string physical modeling -> Bitcrusher -> Freeverb',
  args: args,
  builder: (context, tempo) {
    final clock = Clock.bpm(tempo.bpm);
    final note = Note.parse('C4');

    final node = KarplusStrong(
      gate: clock.gate,
      frequency: .value(note.hz),
      feedback: const .value(0.997),
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
