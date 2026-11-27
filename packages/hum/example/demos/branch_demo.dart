import 'package:hum/hum.dart';

import '../harness.dart';

/// Demonstrates the [Branch] node (N-way weighted trigger/gate router).
///
/// A steady 16th-note clock drives a simple arpeggio while [Branch.uniform]
/// routes each pulse randomly across three oscillator waveforms (sine, square,
/// and sawtooth) sharing the exact same pitch CV and decay envelope — so only
/// the waveform timbre changes from note to note.
void main(List<String> args) => runDemo(
  name: 'branch_demo',
  tempo: const Tempo(128),
  bars: 8,
  description: '3-way Branch router: arpeggio pulses randomly routed across sine, square, and sawtooth',
  args: args,
  configureArgs: (parser) {
    parser.addOption(
      'seed',
      help: 'RNG seed (integer, or "random" for unseeded)',
      defaultsTo: '31',
    );
  },
  builder: (context, tempo, args) {
    final rawSeed = args.option('seed');
    final seed = (rawSeed == null || rawSeed == 'random')
        ? null
        : int.tryParse(rawSeed);

    final clock = Clock(
      frequency: .value(1 / tempo.sixteenth),
      pulseWidth: const .value(0.5),
    );

    final arp = StepSequencer(
      clock: clock.trigger,
      steps: .value('C4 E4 G4 B4 D5 B4 G4 E4'.toHz()),
    );

    final branch = Branch.uniform(
      input: clock.trigger,
      count: 3,
      maxConsecutive: 2,
      seed: seed,
    );

    Outlet env(Outlet trigger) => Decay.pure(
      trigger: trigger,
      time: const .value(0.14),
      curve: .exponential,
    ).outlet;

    final sineVoice = Mult.mono(
      input: SineOscillator(frequency: .signal(arp.cv)).outlet,
      value: .signal(env(branch[0])),
    );

    final squareVoice = Mult.mono(
      input: SquareOscillator(frequency: .signal(arp.cv)).outlet,
      value: .signal(env(branch[1])),
    ).outlet.mult(0.6);

    final sawVoice = Mult.mono(
      input: SawtoothOscillator(frequency: .signal(arp.cv)).outlet,
      value: .signal(env(branch[2])),
    ).outlet.mult(0.7);

    final mix = Sum(
      inputs: [sineVoice.outlet, squareVoice.outlet, sawVoice.outlet],
    );
    return Mult.mono(input: mix.outlet, value: const .value(0.5));
  },
);
