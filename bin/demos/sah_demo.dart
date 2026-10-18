import 'dart:io';

import 'package:hum/hum.dart';

// Gemini generated this, pretty cool

/// A generative modular synthesizer demo showcasing [Sah] (Sample & Hold).
///
/// Features:
/// - **Dual-Channel S&H**: A 16th-note [Clock] triggers [Sah.stereo] on rising edges.
///   - Channel 0 latches a slow drifting sine LFO + pink noise for stepped melodic pitch CV.
///   - Channel 1 latches a faster modulation + noise signal for stepped filter cutoff CV.
/// - **Sub-Oscillator Voice**: Main [SawtoothOscillator] + sub-octave [SquareOscillator].
/// - **Tube Saturation & Filtering**: [Saturator.tube] feeding a resonant [SvfFilter] lowpass.
/// - **Plucked Envelope**: Snappy exponential [Adsr] controlling voice amplitude.
/// - **Stereo Space**: Dotted-eighth [Delay] into wide [Freeverb] diffusion.
void main() {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(132);
  const double bars = 4.0;

  final totalBlocks = tempo.blocksFor(
    bars: bars,
    sampleRate: sr,
    vectorSize: vs,
  );
  final totalDurationSeconds = bars * tempo.bar;
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);

  print('=== Hum Sample & Hold (Sah) Generative Synth Demo ===');
  print(
    'Tempo: ${tempo.bpm} BPM | Duration: $bars bars (${totalDurationSeconds.toStringAsFixed(1)}s)',
  );
  print('Rendering $totalBlocks audio blocks at $sr Hz (vector size: $vs)...');

  // 1. Clock / Trigger: 16th-note pulse train driving both S&H and ADSR
  final clock = Clock(
    frequency: .value(tempo.frequencyOf(NoteValue.sixteenth)),
    pulseWidth: const .value(0.3),
  );

  // 2. Modulators to be sampled:
  // - Pitch source: slow 2-bar drifting sine LFO + subtle pink noise jitter
  final slowLfo = SineOscillator(
    frequency: .value(1 / (tempo.bar * 2)),
  );
  final noise = NoiseGenerator.pink();
  final noiseJitter = Mult.mono(
    value: const .value(0.35),
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
    trigger: clock.outlet,
    leftInput: pitchCvSource,
    rightInput: cutoffCvSource,
    threshold: 0.5,
    triggerEdge: .rising,
  );

  // 4. CV Scaling:
  // - Map pitch S&H (-1.35 to 1.35) into musical frequencies: D2 (73.4 Hz) to D4 (293.7 Hz)
  final pitch = Scale(
    input: sah.outlets[0],
    inLow: const .value(-1.35),
    inHigh: const .value(1.35),
    outLow: .value(Note.parse('D2').hz),
    outHigh: .value(Note.parse('D4').hz),
  );

  // - Sub-octave pitch: D1 to D3
  final subPitch = Scale(
    input: sah.outlets[0],
    inLow: const .value(-1.35),
    inHigh: const .value(1.35),
    outLow: .value(Note.parse('D1').hz),
    outHigh: .value(Note.parse('D3').hz),
  );

  // - Map cutoff S&H (-1.45 to 1.45) into resonant filter cutoff range: 380 Hz to 4200 Hz
  final filterCutoff = Scale(
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

  // 7. Plucked Amplitude Envelope (VCA)
  final env = Adsr(
    gate: clock.outlet,
    attack: const .value(0.004),
    decay: .value(tempo.sixteenth * 0.7),
    sustain: const .value(0.0),
    release: const .value(0.04),
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
    mix: const .value(0.28),
  );

  // 9. WAV Sink Output
  const outputPath = 'tmp/sah_demo.wav';
  final wav = WavSink.file(
    channels: [reverb.left, reverb.right],
    path: outputPath,
  );

  final pipeline = compilePipeline(root: wav, context: context);

  final stopwatch = Stopwatch()..start();
  for (int i = 0; i < totalBlocks; i++) {
    pipeline.process();
  }
  pipeline.processorOf(wav).close();
  stopwatch.stop();

  final file = File(outputPath);
  final sizeKb = (file.lengthSync() / 1024).toStringAsFixed(1);
  final renderMs = stopwatch.elapsedMilliseconds;
  final realtimeMultiple =
      (totalDurationSeconds * 1000 / (renderMs > 0 ? renderMs : 1))
          .toStringAsFixed(1);

  print(
    'Render complete in ${renderMs}ms (~${realtimeMultiple}x faster than real-time)',
  );
  print('Saved stereo audio to: $outputPath ($sizeKb KB)');
}
