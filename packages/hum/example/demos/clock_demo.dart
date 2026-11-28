import 'package:hum/hum.dart';

import '../harness.dart';

/// Demonstrates BPM clock, envelope generation, frequency modulation,
/// bitcrushing, and rhythmic delay.
void main(List<String> args) => runDemo(
  name: 'clock_demo',
  tempo: const Tempo(140),
  bars: 4,
  description: 'Clock synchronization: BPM clock -> ADSR envelope -> FM synths -> Bitcrusher -> Delay',
  args: args,
  builder: (context, tempo, _) {
    final clock = Clock.bpm(tempo.bpm);
    final adsr = Adsr(gate: clock.gate, attack: const .value(0.1));

    final low = Note.parse('A4');
    final high = Note.parse('E5');

    final ramp = SawtoothOscillator(
      frequency: .value(1 / tempo.bar),
      usePolyBlep: false,
    );

    final sine = SineOscillator(
      frequency: .signal(ramp.mapRange(low.hz, high.hz).outlet),
    );
    final saw = SawtoothOscillator(
      frequency: .signal(ramp.mapRange(low.hz / 2, high.hz / 2).outlet),
    );
    final noise = NoiseGenerator.pink();
    final sawScaled = Mult.mono(value: const .value(0.1), input: saw.outlet);
    final noiseScaled = Mult.mono(
      value: const .value(0.25),
      input: noise.outlet,
    );
    final amp = Mult.mono(
      value: .signal(adsr.outlet),
      input: sine.outlet + sawScaled.outlet + noiseScaled.outlet,
    );
    final bitcrush = Bitcrusher.mono(
      input: amp.outlet,
      bitDepth: const .value(4),
      downsample: const .value(0.5),
    );
    final delay = Delay.mono(
      input: bitcrush.outlet,
      time: .value(tempo.tripletEighth),
      feedback: const .value(0.8),
      mix: const .value(0.15),
    );

    return Out.stereo(left: delay.outlet, right: delay.outlet);
  },
);
