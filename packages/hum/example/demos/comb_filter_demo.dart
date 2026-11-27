import 'package:hum/hum.dart';

import '../harness.dart';

/// Demonstrates physical acoustic modeling using the [CombFilter] node.
///
/// A 16th-note clock drives a [StepSequencer] through a minor pentatonic melody.
/// On each step, a tiny 8ms burst of white noise (a plectrum / hammer strike)
/// is fed into a tuned [CombFilter].
///
/// The comb filter's sub-sample fractional delay loop and 1-pole damping
/// transform the raw noise impulse into a warm, ringing acoustic plucked string
/// or marimba voice.
void main(List<String> args) => runDemo(
  name: 'comb_filter_demo',
  tempo: const Tempo(120),
  bars: 4,
  description:
      'Physical modeling string melody: noise impulse burst into tuned resonant CombFilter',
  args: args,
  builder: (context, tempo, _) {
    // 1. Master clock at 16th notes
    final clock = Clock(
      frequency: .value(1 / tempo.sixteenth),
      pulseWidth: const .value(0.5),
    );

    // 2. Pentatonic pitch sequence
    final pitchSeq = StepSequencer.notes(
      clock: clock.trigger,
      notes: [
        'D3', 'F3', 'A3', 'C4', // Bar 1
        'G3', 'F3', 'D3', 'A3', // Bar 2
        'D4', 'C4', 'A3', 'G3', // Bar 3
        'F3', 'G3', 'D3', 'A2', // Bar 4
      ],
    );

    // 3. Noise burst exciter (simulating a plectrum pluck / hammer strike)
    final noise = NoiseGenerator.white();
    final strikeEnv = Decay.pure(
      trigger: clock.trigger,
      time: const .value(0.008), // Snappy 8ms burst of noise
      curve: .exponential,
    );
    final exciter = Mult.mono(
      input: noise.outlet,
      value: .signal(strikeEnv.outlet),
    );

    // 4. Tuned Resonant Comb Filter:
    // Converts the 8ms noise click into an acoustic plucked string tone.
    // High feedback (0.97) for ringing sustain, 1-pole damping (0.40) for warm woody decay.
    final combL = CombFilter.mono(
      input: exciter.outlet,
      frequency: .signal(pitchSeq.outlet),
      feedback: const .value(0.97),
      damp: const .value(0.40),
      mix: const .value(1.0),
    );

    // Right channel with slight pitch offset (+1.2 Hz) for stereo acoustic body width
    final pitchR = Add.mono(
      input: pitchSeq.outlet,
      value: const .value(1.2),
    );
    final combR = CombFilter.mono(
      input: exciter.outlet,
      frequency: .signal(pitchR.outlet),
      feedback: const .value(0.97),
      damp: const .value(0.45),
      mix: const .value(1.0),
    );

    // 5. Subtle Freeverb for acoustic room ambience
    final reverb = Freeverb.stereo(
      left: combL.outlet,
      right: combR.outlet,
      roomSize: const .value(0.60),
      damp: const .value(0.35),
      width: const .value(0.8),
      mix: const .value(0.25),
    );

    return Out.stereo(left: reverb.left, right: reverb.right);
  },
);
