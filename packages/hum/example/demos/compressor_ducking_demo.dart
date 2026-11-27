import 'package:hum/hum.dart';

import '../harness.dart';

/// Demonstrates sidechain ducking compression with [Compressor].
///
/// In modern electronic music (house, techno, synthwave, EDM), sidechain
/// compression ducks the bassline every time the kick drum fires. This creates:
/// 1. Low-end clarity: the kick transient punches through without clashing with the sub bass.
/// 2. Iconic rhythmic "pumping" groove.
void main(List<String> args) => runDemo(
  name: 'compressor_ducking_demo',
  tempo: const Tempo(128),
  bars: 4,
  description: 'Four-on-the-floor kick ducking an acid synth bassline via sidechain compression.',
  args: args,
  builder: (context, tempo, _) {
    // 1. Kick Drum Synthesizer: 4-on-the-floor (quarter notes)
    final kickClock = Clock(
      frequency: .value(1 / tempo.beat),
      pulseWidth: const .value(0.1),
    );

    // Fast pitch drop from 165 Hz to 45 Hz for deep punch
    final kickPitchEnv = Decay.pure(
      trigger: kickClock.trigger,
      time: const .value(0.045),
      curve: .exponential,
    );
    final kickPitch = kickPitchEnv.outlet.mapRange(
      45.0,
      165.0,
      inLow: 0.0,
      inHigh: 1.0,
    );
    final kickOsc = SineOscillator(frequency: .signal(kickPitch.outlet));

    // Kick amplitude envelope
    final kickAmpEnv = Decay.pure(
      trigger: kickClock.trigger,
      time: const .value(0.22),
      curve: .exponential,
    );
    final kickVoice = Mult.mono(
      input: kickOsc.outlet,
      value: .signal(kickAmpEnv.outlet),
    );

    // 2. Rolling Synth Bassline: 16th notes with lowpass resonance
    final bassClock = Clock(
      frequency: .value(1 / tempo.sixteenth),
      pulseWidth: const .value(0.5),
    );

    final bassSeq = StepSequencer.notes(
      clock: bassClock.trigger,
      notes: ['D1', 'D2', 'D1', 'F1', 'D1', 'D2', 'G1', 'A1'],
    );
    final bassSaw = SawtoothOscillator(frequency: .signal(bassSeq.outlet));

    final bassFilter = SvfFilter(
      input: bassSaw.outlet,
      cutoff: const .value(650.0),
      resonance: const .value(1.8),
    );

    final bassEnv = Adsr(
      gate: bassClock.gate,
      attack: const .value(0.005),
      decay: const .value(0.080),
      sustain: const .value(0.65),
      release: const .value(0.040),
      curve: .exponential,
    );

    final rawBass = Mult.mono(
      input: bassFilter.lowpass,
      value: .signal(bassEnv.outlet),
    );

    // 3. Sidechain Compression: Duck the bass whenever the kick hits
    // - Threshold: -22 dB
    // - Ratio: 8:1 (heavy ducking)
    // - Attack: 2 ms (instant transient clamp)
    // - Release: 180 ms (musical breathing pump returning before the next beat)
    final duckedBass = Compressor.mono(
      rawBass.outlet,
      sidechain: kickVoice.outlet,
      threshold: const .value(-22.0),
      ratio: const .value(8.0),
      attack: const .value(0.002),
      release: const .value(0.180),
      knee: const .value(4.0),
    );

    // 4. Mix Bus: Combine kick and ducked bass into stereo master
    final mix = kickVoice.outlet + duckedBass.outlet;

    return Mult.stereo(
      leftInput: mix,
      rightInput: mix,
      value: const .value(0.65),
    );
  },
);
