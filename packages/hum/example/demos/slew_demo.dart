import 'package:hum/hum.dart';

import '../harness.dart';

/// A dedicated, musical demonstration of [Slew] / [Portamento] / [Lag].
///
/// Features an alternating 2-octave synth lead (A2 110 Hz <-> A4 440 Hz)
/// with articulated phrasing and headroom to clearly hear how slew shapes
/// note transitions without distortion or clipping.
///
/// The demo progresses through 4 distinct 4-second stages across 8 bars:
/// 1. **Stage 1 (0.0s - 4.0s)**: Slew = 0.0s (Instant staccato octave jumps, zero glide)
/// 2. **Stage 2 (4.0s - 8.0s)**: Slew = 0.08s (Snappy, classic synthesizer portamento)
/// 3. **Stage 3 (8.0s - 12.0s)**: Slew = 0.30s (Deep, dramatic siren-like sweeps)
/// 4. **Stage 4 (12.0s - 16.0s)**: Asymmetric Slew (0.35s slow rise glide, 0.0s instant snap fall)
void main(List<String> args) => runDemo(
  name: 'slew_demo',
  tempo: const Tempo(120),
  bars: 8,
  description:
      'Slew/Portamento: Alternating 2-octave lead cycling through 4 stages of glide times',
  args: args,
  builder: (context, tempo, _) {
    // 1. Note Clock: 2 notes per second (120 BPM quarter notes)
    // Gate stays high for 80% of the note (0.4s note, 0.1s space)
    final noteClock = Clock(
      frequency: const .value(2.0),
      pulseWidth: const .value(0.8),
    );

    // 2. Alternating pitch CV: 1.0 Hz square wave (changes every 0.5s, synchronized with note clock)
    final pitchLfo = SquareOscillator(
      frequency: const .value(1.0),
      usePolyBlep: false,
    );
    final cv = MapRange.bipolar(
      input: pitchLfo.outlet,
      outLow: 0.0,
      outHigh: 1.0,
    );

    // 3. Stage Sequencer: advances every 2 bars (4.0 seconds @ 120 BPM)
    final stageClock = Clock(
      frequency: .value(1.0 / (tempo.bar * 2)),
    );
    final riseSeq = StepSequencer.fromList(
      clock: stageClock.trigger,
      steps: const [0.0, 0.08, 0.30, 0.35],
    );
    final fallSeq = StepSequencer.fromList(
      clock: stageClock.trigger,
      steps: const [0.0, 0.08, 0.30, 0.0],
    );

    // 4. Slew Node:
    // Operating on the 0.0 -> 1.0 CV signal.
    // Because step height is 1.0 unit, the slew time in seconds matches the glide duration exactly.
    final slew = Slew.mono(
      input: cv.outlet,
      rise: .signal(riseSeq.outlet),
      fall: .signal(fallSeq.outlet),
    );

    // 5. Pitch Scaling:
    // Maps 0.0 -> A2 (110 Hz) and 1.0 -> A4 (440 Hz)
    final pitch = MapRange.unipolar(
      input: slew.outlet,
      outLow: Note.parse('A2').hz,
      outHigh: Note.parse('A4').hz,
    );

    // 6. Synth Voice:
    // Warm sawtooth oscillator through a 1200 Hz resonant lowpass filter.
    final saw = SawtoothOscillator(
      frequency: .signal(pitch.outlet),
    );
    final filter = SvfFilter(
      input: saw.outlet,
      cutoff: const .value(1200.0),
      resonance: const .value(1.2),
    );

    // 7. Amplitude Envelope:
    // Smooth attack, sustained body, and clean release for articulated notes.
    final env = Adsr(
      gate: noteClock.gate,
      attack: const .value(0.01),
      decay: const .value(0.15),
      sustain: const .value(0.7),
      release: const .value(0.08),
      curve: .exponential,
    );
    final voiced = Mult.mono(
      value: ControlParam.signal(env.outlet),
      input: filter.lowpass,
    );

    // 8. Master Gain:
    // Scaled to 0.35 to guarantee clean headroom and zero clipping.
    final master = Mult.mono(
      value: const .value(0.35),
      input: voiced.outlet,
    );

    // Subtle rhythmic stereo delay
    final delay = Delay.mono(
      input: master.outlet,
      time: const .value(0.25),
      feedback: const .value(0.3),
      mix: const .value(0.25),
    );

    return Out.stereo(left: master.outlet, right: delay.outlet);
  },
);
