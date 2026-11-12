import 'dart:async';
import 'dart:io';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';

void main(List<String> args) async {
  const sampleRate = 44100;
  const vectorSize = 128;
  const outputFile = 'tmp/mic_recording.wav';
  const recordDurationSeconds = 5;

  final context = ProcessContext(
    sampleRate: sampleRate,
    vectorSize: vectorSize,
  );

  final useFfmpeg = args.contains('--ffmpeg');
  final useSox = args.contains('--sox');

  final SubprocessSource source = switch ((useFfmpeg, useSox)) {
    (true, false) => SubprocessSource.ffmpeg(
      numChannels: 1,
      sampleRate: sampleRate,
      format: .float32,
    ),
    (false, true) => SubprocessSource.sox(
      numChannels: 1,
      sampleRate: sampleRate,
      format: .float32,
    ),
    _ => SubprocessSource.mic(
      numChannels: 1,
      sampleRate: sampleRate,
      format: .float32,
    ),
  };

  stdout.writeln('========================================');
  stdout.writeln('  hum Microphone Recording Demo');
  stdout.writeln('========================================');
  stdout.writeln(
    '• Backend: ${source.executable} (${source.arguments.join(' ')})',
  );
  stdout.writeln('• Sample rate: $sampleRate Hz');
  stdout.writeln('• Destination: $outputFile');
  stdout.writeln('• Duration: $recordDurationSeconds seconds');
  stdout.writeln('----------------------------------------');

  final delay = Delay.mono(
    input: source.outlet,
    feedback: const .value(0.91),
    damp: const .value(0.1),
  );

  final targetFile = File(outputFile);
  if (targetFile.existsSync()) {
    targetFile.deleteSync();
  }

  final sink = WavSink.file(
    channels: [delay.outlet],
    path: outputFile,
    format: .float32,
  );

  final host = await IsolateAudioHost.spawn(context: context);
  final diagnostics = host.setGraph(root: sink);
  if (diagnostics.isNotEmpty) {
    stderr.writeln('Graph validation error: $diagnostics');
    await host.dispose();
    exit(1);
  }

  // Calling `startPlayback()` with no `AudioOutput` works!
  await host.startPlayback();

  stdout.writeln('🎙️  Recording started! Speak, sing, or tap your mic...');

  for (int remaining = recordDurationSeconds; remaining > 0; remaining--) {
    final progress = '=' * (recordDurationSeconds - remaining + 1);
    final empty = ' ' * (remaining - 1);
    stdout.write('\r[$progress$empty] $remaining s remaining... ');
    await Future.delayed(const Duration(seconds: 1));
  }
  stdout.writeln(
    '\r[${'=' * recordDurationSeconds}] Done! Finalizing WAV...      ',
  );

  await host.stopPlayback();
  await host.dispose();

  if (targetFile.existsSync()) {
    final bytes = targetFile.lengthSync();
    final audioBytes = bytes > 44 ? bytes - 44 : 0;
    final recordedSeconds = audioBytes / (sampleRate * 4); // 4 bytes/float
    stdout.writeln('----------------------------------------');
    stdout.writeln(' Recorded file created successfully!');
    stdout.writeln('• File: ${targetFile.path}');
    stdout.writeln(
      '• Size: ${(bytes / 1024).toStringAsFixed(1)} KB ($bytes bytes)',
    );
    stdout.writeln('• Duration: ${recordedSeconds.toStringAsFixed(2)} seconds');
    stdout.writeln('----------------------------------------');
    stdout.writeln('To play back your recording, run:');
    stdout.writeln('  ffplay -autoexit -nodisp $outputFile');
    stdout.writeln('  # or: play $outputFile');
  } else {
    stderr.writeln('Error: $outputFile was not created.');
  }
}
