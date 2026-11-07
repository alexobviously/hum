import 'dart:io';

import 'package:hum/hum.dart';

// Gemini made this one too

/// A musical synthesizer demo showcasing [Tah] (Track & Hold).
///
/// Features demonstrated:
/// 1. **Glide-and-Hold Rhythmic Pitch Modulation**:
///    - A continuous sine LFO is fed into [Tah].
///    - A syncopated clock gate allows the pitch to smoothly glide during the "high" portion,
///      then immediately freezes flat at whatever instantaneous pitch it reached during the "low" portion.
/// 2. **Audio-Rate Waveshaper (Formant Decimator)**:
///    - The raw oscillator tone is also processed through an audio-rate [Tah] clocked by a high-frequency
///      pulse. This alternates between passing pure audio and freezing single-sample DC lines,
///      imparting rich formant grit and metallic bite.
/// 3. **Spatial Effects**:
///    - Filtered with [SvfFilter.lowpass], rhythmic [Delay], and wide [Freeverb] space.
void main() {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(124);
  const double bars = 4.0;

  final totalBlocks = tempo.blocksFor(
    bars: bars,
    sampleRate: sr,
    vectorSize: vs,
  );
  final totalDurationSeconds = bars * tempo.bar;
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);

  print('=== Hum Track & Hold (Tah) Synth Demo ===');
  print(
    'Tempo: ${tempo.bpm} BPM | Duration: $bars bars (${totalDurationSeconds.toStringAsFixed(1)}s)',
  );
  print('Rendering $totalBlocks audio blocks at $sr Hz (vector size: $vs)...');

  // 1. Rhythmic Gate: 8th-note clock with 40% duty cycle (tracks for 40%, holds for 60%)
  final rhythmicGate = Clock(
    frequency: .value(tempo.frequencyOf(NoteValue.eighth)),
    pulseWidth: const .value(0.4),
  );

  // 2. Continuous Modulator: 1-bar Sine LFO
  final pitchLfo = SineOscillator(
    frequency: .value(1 / tempo.bar),
  );

  // 3. Track & Hold on CV (Glide-and-Hold):
  // - While rhythmicGate is high (40% of the beat), it tracks the smooth sine curve (glide).
  // - While rhythmicGate is low (60% of the beat), it freezes the last sample flat (hold).
  final pitchTah = Tah.mono(
    gate: rhythmicGate.gate,
    input: pitchLfo.outlet,
    threshold: 0.5,
  );

  // Map the glide-and-hold CV to musical notes: A2 (110 Hz) to A4 (440 Hz)
  final noteLow = Note.parse('A2').hz;
  final noteHigh = Note.parse('A4').hz;
  final pitchCv = MapRange.bipolar(
    input: pitchTah.outlet,
    outLow: noteLow,
    outHigh: noteHigh,
  );

  // 4. Synth Voice: Sawtooth driven by the glide-and-hold pitch
  final saw = SawtoothOscillator(
    frequency: .signal(pitchCv.outlet),
  );

  // 5. Audio-Rate Track & Hold (Timbral Waveshaping):
  // - Clock the audio with a fast 600 Hz pulse.
  // - Passing audio through a fast T&H creates harmonic formant grit as it alternates
  //   between tracking the live wave and freezing single-sample DC plateaus.
  final crushClock = Clock(
    frequency: const .value(600),
    pulseWidth: const .value(0.65),
  );
  final shapedAudio = Tah.mono(
    gate: crushClock.gate,
    input: saw.outlet,
    threshold: 0.5,
  );

  // Blend 70% clean saw + 30% shaped audio for subtle texture
  final blendedAudio =
      saw.outlet +
      Mult.mono(
        value: const .value(0.3),
        input: shapedAudio.outlet,
      ).outlet;

  // 6. Resonant Lowpass Filter with modulated cutoff
  final filter = SvfFilter(
    input: blendedAudio,
    cutoff: const .value(1800),
    resonance: const .value(2.8),
  );

  // 7. Envelope: Snappy percussive articulation on each 8th note
  final env = Adsr(
    gate: rhythmicGate.gate,
    attack: const .value(0.005),
    decay: .value(tempo.eighth * 0.8),
    sustain: const .value(0.15),
    release: const .value(0.05),
    curve: .exponential,
  );
  final voiced = Mult.mono(
    value: ControlParam.signal(env.outlet),
    input: filter.lowpass,
  );

  // 8. Stereo Space: Dotted-eighth delay into Freeverb
  final delay = Delay.mono(
    input: voiced.outlet,
    time: .value(tempo.dottedEighth),
    feedback: const .value(0.48),
    mix: const .value(0.3),
  );
  final reverb = Freeverb.mono(
    input: delay.outlet,
    roomSize: const .value(0.75),
    damp: const .value(0.3),
    width: const .value(1.0),
    mix: const .value(0.25),
  );

  // 9. Write to WAV
  const outputPath = 'tmp/tah_demo.wav';
  final wav = WavSink.file(
    channels: [reverb.left, reverb.right],
    path: outputPath,
  );

  final pipeline = compilePipeline(root: wav, context: context).pipeline!;
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
