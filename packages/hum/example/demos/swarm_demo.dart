import 'package:hum/hum.dart';

import '../harness.dart';

void main(List<String> args) => runDemo(
  name: 'swarm_demo',
  tempo: const Tempo(100),
  bars: 2,
  description: 'bzzzzz',
  args: args,
  builder: (context, tempo, _) {
    final lfo = SineOscillator(frequency: .value(0.2))
        .mapRange(noteToHz('A3'), noteToHz('C3'));
    final swarm = Swarm.square(frequency: .signal(lfo.outlet), voices: 20);

    final saturator = Saturator(
      channels: [swarm.left, swarm.right],
      drive: const .value(1.8),
      mix: const .value(1.0),
      dcBlock: true,
      mode: .cubic,
    );

    final filtered = [saturator.left, saturator.right].map(_filter);

    final clock = Clock(frequency: .value(1 / tempo.quarter));
    final pulse = Decay(
      trigger: clock.trigger,
      decay: const .value(.1),
    );

    final sidechained = Compressor(
      channels: filtered.map((e) => e.outlet).toList(),
      sidechain: pulse.outlet,
      threshold: const .value(-28.0),
      ratio: const .value(3.0),
      attack: const .value(0.002),
      release: const .value(0.180),
      knee: const .value(4.0),
      makeupGain: const .value(12),
    );

    return Out(channels: sidechained.outlets);
  },
);

SvfFilter _filter(Outlet audio) => SvfFilter(input: audio, cutoff: .value(500));
