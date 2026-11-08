import 'dart:io';

import 'package:hum/hum.dart';

/// Demonstrates sidechain ducking compression with [Compressor].
///
/// In modern electronic music (house, techno, synthwave, EDM), sidechain
/// compression ducks the bassline every time the kick drum fires. This creates:
/// 1. Low-end clarity: the kick transient punches through without clashing with the sub bass.
/// 2. Iconic rhythmic "pumping" groove.
///
/// Run to bounce WAV:
///   dart run example/demos/compressor_ducking_demo.dart
///
/// Run with real-time playback (requires ffplay):
///   dart run example/demos/compressor_ducking_demo.dart --play
void main(List<String> args) async {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(128);

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

  final master = Mult.stereo(
    leftInput: mix,
    rightInput: mix,
    value: const .value(0.65),
  );

  const outputPath = 'tmp/compressor_ducking_demo.wav';
  final shouldPlay = args.contains('--play');

  if (shouldPlay) {
    print('Starting real-time playback via ffplay at 128 BPM...');
    print('Press Ctrl+C to stop.');

    final output = await PipedAudioOutput.ffplay(
      numChannels: 2,
      vectorSize: vs,
      sampleRate: sr,
    );

    final terminal = Out.stereo(
      left: master.outlets[0],
      right: master.outlets[1],
    );

    final host = await AudioHost.spawn(
      context: const ProcessContext(sampleRate: sr, vectorSize: vs),
    );

    final diagnostics = host.setGraph(root: terminal);
    if (diagnostics.isNotEmpty) {
      stderr.writeln('Graph compilation errors: $diagnostics');
      await output.close();
      await host.dispose();
      return;
    }

    await host.startPlayback(output);

    // Play for 8 bars (~15 seconds)
    final durationSeconds = tempo.bar * 8;
    await Future.delayed(
      Duration(milliseconds: (durationSeconds * 1000).toInt()),
    );

    await host.stopPlayback();
    await output.close();
    await host.dispose();
    print('Playback completed.');
  } else {
    // Render 4 bars of audio to WAV
    final blocks = tempo.blocksFor(bars: 4, sampleRate: sr, vectorSize: vs);
    final context = const ProcessContext(sampleRate: sr, vectorSize: vs);

    final wav = WavSink.file(
      channels: master.outlets,
      path: outputPath,
    );

    final compileResult = compilePipeline(root: wav, context: context);
    if (compileResult.hasErrors) {
      stderr.writeln('Compilation diagnostics: ${compileResult.diagnostics}');
      return;
    }

    final pipeline = compileResult.pipeline!;
    print('Rendering 4 bars of sidechain ducking demo at 128 BPM...');

    for (int i = 0; i < blocks; i++) {
      pipeline.process();
    }

    pipeline.processorOf(wav).close();
    print('WAV successfully saved to $outputPath');
    print('To play: ffplay -autoexit -nodisp $outputPath');
    print(
      'Or run with: dart run example/demos/compressor_ducking_demo.dart --play',
    );
  }
}
