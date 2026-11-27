import 'package:hum/hum.dart';

import '../harness.dart';

/// A generative modular synthesizer demo showcasing [Sah] (Sample & Hold)
/// paired with a dynamic [Slew] rate limiter (portamento / glide).
///
/// Features:
/// - **Dual-Channel S&H**: A 16th-note [Clock] triggers [Sah.stereo] on rising edges.
///   - Channel 0 latches a slow drifting sine LFO + pink noise for stepped melodic pitch CV.
///   - Channel 1 latches a faster modulation + noise signal for stepped filter cutoff CV.
/// - **Dynamic Slew / Portamento**: A slow unipolar ramp increases slew time from 0.0s to
///   0.12s across 8 bars, evolving the melody from robotic staccato jumps to rich glides.
/// - **Sub-Oscillator Voice**: Main [SawtoothOscillator] + sub-octave [SquareOscillator].
/// - **Tube Saturation & Filtering**: [Saturator.tube] feeding a resonant [SvfFilter] lowpass.
/// - **Amplitude Envelope**: Exponential [Adsr] with subtle sustain for expressive glides.
/// - **Stereo Space**: Dotted-eighth [Delay] into wide [Freeverb] diffusion.
void main(List<String> args) => runDemo(
  name: 'sah_demo',
  tempo: const Tempo(132),
  bars: 8,
  description:
      'Generative modular synth: dual-channel S&H + dynamic slew (portamento glide) -> delay -> Freeverb',
  args: args,
  builder: (context, tempo, _) {
    final totalDurationSeconds = 8.0 * tempo.bar;

    // 1. Clock / Trigger: 16th-note pulse train driving both S&H and ADSR
    final clock = Clock(
      frequency: .value(tempo.frequencyOf(NoteValue.sixteenth)),
      pulseWidth: const .value(0.3),
    );

    // 2. Modulators to be sampled:
    // - Pitch source: drifting sine LFO + expressive noise for distinct melodic jumps
    final slowLfo = SineOscillator(
      frequency: .value(1 / (tempo.bar * 2)),
    );
    final noise = NoiseGenerator.pink();
    final noiseJitter = Mult.mono(
      value: const .value(0.85),
      input: noise.outlet,
    );
    final pitchCvSource = slowLfo.outlet + noiseJitter.outlet;

    // - Cutoff source: 1-bar triangle wave + pink noise
    final cutoffLfo = TriangleOscillator(
      frequency: .value(1 / tempo.bar),
    );
    final cutoffNoise = Mult.mono(
      value: const .value(0.45),
      input: noise.outlet,
    );
    final cutoffCvSource = cutoffLfo.outlet + cutoffNoise.outlet;

    // 3. Sample & Hold: Latches both signals synchronously on each 16th-note pulse
    final sah = Sah.stereo(
      trigger: clock.trigger,
      leftInput: pitchCvSource,
      rightInput: cutoffCvSource,
      threshold: 0.5,
      triggerEdge: .rising,
    );

    // 4. Slew / Portamento Modulation:
    // Ramps slew time from 0.0s (instantaneous staccato steps) to 0.12s (smooth portamento glides)
    // across the duration of the audio.
    final slewRamp = SawtoothOscillator(
      frequency: .value(1.0 / totalDurationSeconds),
      usePolyBlep: false,
    );
    final slewTime = MapRange.bipolar(
      input: slewRamp.outlet,
      outLow: 0.0,
      outHigh: 0.6,
    );

    // Apply slew rate limiting to the stepped pitch CV
    final slewedPitch = Slew.mono(
      input: sah.outlets[0],
      time: .signal(slewTime.outlet),
    );

    // 5. CV Scaling:
    // - Map slewed pitch S&H (-1.85 to 1.85) into musical frequencies: D2 (73.4 Hz) to D4 (293.7 Hz)
    final pitch = MapRange(
      input: slewedPitch.outlet,
      inLow: const .value(-1.85),
      inHigh: const .value(1.85),
      outLow: .value(Note.parse('D2').hz),
      outHigh: .value(Note.parse('D4').hz),
    );

    // - Sub-octave pitch: D1 to D3
    final subPitch = MapRange(
      input: slewedPitch.outlet,
      inLow: const .value(-1.85),
      inHigh: const .value(1.85),
      outLow: .value(Note.parse('D1').hz),
      outHigh: .value(Note.parse('D3').hz),
    );

    // - Map cutoff S&H (-1.45 to 1.45) into resonant filter cutoff range: 380 Hz to 4200 Hz
    final filterCutoff = MapRange(
      input: sah.outlets[1],
      inLow: const .value(-1.45),
      inHigh: const .value(1.45),
      outLow: const .value(380.0),
      outHigh: const .value(4200.0),
    );

    // 5. Sound Generators:
    final mainSaw = SawtoothOscillator(
      frequency: .signal(pitch.outlet),
    );
    final subSquare = SquareOscillator(
      frequency: .signal(subPitch.outlet),
    );
    final subScaled = Mult.mono(
      value: const .value(0.4),
      input: subSquare.outlet,
    );
    final oscMix = mainSaw.outlet + subScaled.outlet;

    // 6. Warm Tube Saturation & Dynamic Resonant Filter
    final saturated = Saturator.tube(
      oscMix,
      drive: const .value(1.6),
    );
    final filter = SvfFilter(
      input: saturated.outlet,
      cutoff: .signal(filterCutoff.outlet),
      resonance: const .value(3.2),
    );

    // 7. Expressive Amplitude Envelope (VCA)
    final env = Adsr(
      gate: clock.gate,
      attack: const .value(0.004),
      decay: .value(tempo.sixteenth * 0.85),
      sustain: const .value(0.18),
      release: const .value(0.06),
      curve: .exponential,
    );
    final pluckedVoice = Mult.mono(
      value: ControlParam.signal(env.outlet),
      input: filter.lowpass,
    );

    // 8. Stereo Space & Time-Domain FX:
    // - Dotted-eighth rhythmic delay
    final delay = Delay.mono(
      input: pluckedVoice.outlet,
      time: .value(tempo.dottedEighth),
      feedback: const .value(0.52),
      mix: const .value(0.35),
    );

    // - Schroeder-Moorer algorithmic reverberation with wide stereo decorrelation
    final reverb = Freeverb.mono(
      input: delay.outlet,
      roomSize: const .value(0.78),
      damp: const .value(0.3),
      width: const .value(1.0),
      mix: const .value(0.15),
    );

    // 9. Master Volume (clean headroom staging)
    final master = Mult.stereo(
      value: const .value(0.3),
      leftInput: reverb.left,
      rightInput: reverb.right,
    );

    return Out.stereo(left: master.outlets[0], right: master.outlets[1]);
  },
);
