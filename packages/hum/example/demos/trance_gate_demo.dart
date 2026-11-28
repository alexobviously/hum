import 'package:hum/hum.dart';

import '../harness.dart';

/// Demonstrates stereo-linked sidechain gating with [NoiseGate]:
/// a lush stereo supersaw chord pad chopped by a syncopated 16th-note
/// sidechain pattern, with LFO-modulated gate hold time and subtle post-gate reverb.
void main(List<String> args) => runDemo(
  name: 'trance_gate_demo',
  tempo: const Tempo(132),
  bars: 8,
  description: 'Sidechain trance gate: Stereo Swarm chord pad -> SVF sweep -> NoiseGate (16th-note sidechain + LFO hold) -> Freeverb',
  args: args,
  configureArgs: (parser) {
    parser.addOption(
      'range',
      help: 'Gate attenuation floor in dB (e.g. -22 for pumping, -80 for hard chop)',
      defaultsTo: '-22',
    );
  },
  builder: (context, tempo, rawArgs) {
    final rangeDb = double.tryParse(rawArgs.option('range') ?? '') ?? -22.0;

    // 1-bar clock driving a 4-chord progression (Am7 -> Fmaj7 -> Cmaj7 -> Gadd9)
    final barClock = Clock(
      frequency: .value(1 / tempo.bar),
      pulseWidth: const .value(0.5),
    );

    final chords = [
      ['A2', 'E3', 'G3', 'C4'], // Am7
      ['F2', 'C3', 'E3', 'A3'], // Fmaj7
      ['C3', 'G3', 'B3', 'E4'], // Cmaj7
      ['G2', 'D3', 'A3', 'B3'], // Gadd9
    ];

    final padLeft = <Outlet>[];
    final padRight = <Outlet>[];

    for (int voice = 0; voice < 4; voice++) {
      final pitches = [for (final c in chords) Note.parse(c[voice]).hz];
      final seq = StepSequencer.fromList(
        clock: barClock.trigger,
        steps: pitches,
      );
      final smoothPitch = seq.cv.slew(0.025, pitches.first);
      final swarm = Swarm.sawtooth(
        frequency: .signal(smoothPitch.outlet),
        voices: 5,
        detuneCents: 14.0,
        stereoSpread: 0.85,
      );
      padLeft.add(swarm.left);
      padRight.add(swarm.right);
    }

    final rawLeft = padLeft.sum.outlet.mult(0.22);
    final rawRight = padRight.sum.outlet.mult(0.22);

    // Slow 4-bar filter sweep across the supersaw pad
    final cutoffLfo = SineOscillator(
      frequency: .value(1 / (tempo.bar * 4)),
    ).mapRange(650.0, 3400.0);

    final filtL = SvfFilter(
      input: rawLeft.outlet,
      cutoff: .signal(cutoffLfo.outlet),
      resonance: const .value(1.8),
    );
    final filtR = SvfFilter(
      input: rawRight.outlet,
      cutoff: .signal(cutoffLfo.outlet),
      resonance: const .value(1.8),
    );

    // Syncopated 16th-note sidechain key pattern
    final sixteenthClock = Clock(
      frequency: .value(1 / tempo.sixteenth),
      pulseWidth: const .value(0.55),
    );

    final gatePattern = StepSequencer.fromList(
      clock: sixteenthClock.trigger,
      steps: const [
        1.0,
        0.0,
        1.0,
        1.0,
        0.0,
        1.0,
        1.0,
        0.0,
        1.0,
        0.0,
        1.0,
        1.0,
        0.0,
        1.0,
        0.0,
        1.0,
      ],
    );

    // Multiply pattern by 16th clock gate so consecutive active steps re-articulate cleanly
    final sidechainKey = Mult.mono(
      input: gatePattern.cv,
      value: .signal(sixteenthClock.gate),
    );

    // Slowly morph gate hold time from tight staccato (10ms) to swelling groove (75ms)
    final holdLfo = SineOscillator(
      frequency: .value(1 / (tempo.bar * 4)),
    ).mapRange(0.010, 0.075);

    // Stereo-linked NoiseGate chopping the pad via the external sidechain key
    final gated = NoiseGate.stereo(
      filtL.lowpass,
      filtR.lowpass,
      sidechain: sidechainKey.outlet,
      threshold: const .value(-12.0),
      hysteresis: const .value(2.0),
      range: .value(rangeDb),
      attack: const .value(0.004),
      hold: .signal(holdLfo.outlet),
      release: const .value(0.045),
    );

    // Post-gate stereo reverb for shimmer without washing out the rhythmic chop
    final verb = Freeverb.stereo(
      left: gated.left,
      right: gated.right,
      roomSize: const .value(0.72),
      damp: const .value(0.4),
      mix: const .value(0.22),
    );

    // Four-on-the-floor kick anchor so the syncopated gate locks to a clear pulse
    final kickClock = Clock(frequency: .value(1 / tempo.quarter));
    final kick = Kick(trigger: kickClock.trigger);
    final kickBus = kick.outlet.mult(0.5);

    final mixL = (verb.left + kickBus.outlet).mult(0.8);
    final mixR = (verb.right + kickBus.outlet).mult(0.8);

    return Out.stereo(left: mixL.outlet, right: mixR.outlet);
  },
);
