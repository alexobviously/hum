import 'package:hum/hum.dart';

import '../harness.dart';

/// Demonstrates [WavetableOscillator] with real-time frame morphing.
///
/// Sweeps a slow LFO across [Wavetable.formants] (A -> E -> I -> O -> U)
/// layered with a sub-octave [Wavetable.basicShapes] bassline, finished with
/// chorus and reverb.
///
/// Welcome to na pali, watch out for skaarj..
void main(List<String> args) {
  final buffers = DemoBuffers();
  final formantTable = buffers.loadWavetable(Wavetable.formants());
  final shapesTable = buffers.loadWavetable(Wavetable.basicShapes());

  runDemo(
    name: 'wavetable_demo',
    tempo: const Tempo(110),
    bars: 8,
    description: 'WavetableOscillator: formant vowel morphing arpeggio + morphing sub-bass',
    buffers: buffers,
    args: args,
    builder: (context, tempo, _) {
      final clock = Clock(
        frequency: .value(1 / tempo.eighth),
        pulseWidth: const .value(0.5),
      );
      final arp = StepSequencer(
        clock: clock.trigger,
        steps: .value('A2 E3 A3 C4 B3 G3 E3 D3'.toHz()),
      );

      // Slow LFO sweeping vowel formants A -> E -> I -> O -> U -> A
      final morphLfo = SineOscillator(
        frequency: const .value(0.18),
      ).mapRange(0.0, 1.0);

      final lead = WavetableOscillator(
        wavetable: formantTable,
        frequency: .signal(arp.cv),
        position: .signal(morphLfo.outlet),
      );
      final leadEnv = Decay.pure(
        trigger: clock.trigger,
        time: const .value(0.32),
        curve: .exponential,
      );
      final leadVoice = Mult.mono(
        input: lead.outlet,
        value: .signal(leadEnv.outlet),
      );

      // Sub drone morphing sine -> triangle -> saw -> square
      final subMorph = SineOscillator(
        frequency: const .value(0.11),
      ).mapRange(0.0, 0.7);
      final sub = WavetableOscillator(
        wavetable: shapesTable,
        frequency: .value(Note.parse('A1').hz),
        position: .signal(subMorph.outlet),
      );
      final subFiltered = SvfFilter(
        input: sub.outlet,
        cutoff: const .value(260.0),
      );

      final mix =
          leadVoice.outlet.mult(0.55).outlet +
          subFiltered.lowpass.mult(0.45).outlet;

      final chorus = Chorus.toStereo(input: mix, rate: const .value(0.35));
      final reverb = Freeverb.stereo(
        left: chorus.left,
        right: chorus.right,
        roomSize: const .value(0.75),
        mix: const .value(0.3),
      );

      return Out.stereo(
        left: reverb.left.mult(0.6).outlet,
        right: reverb.right.mult(0.6).outlet,
      );
    },
  );
}
