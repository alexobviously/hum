import 'dart:io';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';

TerminalNode _graph(double frequency) {
  final osc = SineOscillator(frequency: .value(frequency));
  final gain = Mult.mono(input: osc.outlet, value: const .value(0.2));

  return Out.stereo(left: gain.outlet, right: gain.outlet);
}

void main() async {
  const sampleRate = 44100;
  const vectorSize = 64;
  final context = ProcessContext(
    sampleRate: sampleRate,
    vectorSize: vectorSize,
  );

  // Initialize AudioHost and compile the declarative graph
  final host = await IsolateAudioHost.spawn(context: context);

  void setGraph(double frequency) {
    final diagnostics = host.setGraph(root: _graph(frequency));
    if (diagnostics.isNotEmpty) {
      stderr.writeln('Graph compilation failed: $diagnostics');
      return;
    }
  }

  setGraph(440);

  // Create ffplay audio output destination
  final output = PipedAudioOutput.ffplay(
    numChannels: 2,
    vectorSize: vectorSize,
    sampleRate: sampleRate,
  );

  print('Playing 440 Hz sine wave via ffplay for 3 seconds...');
  print('Press Ctrl+C to abort.');

  // Start real-time playback engine with backpressure
  await host.startPlayback(output);

  // Stream for 3 seconds
  await Future.delayed(const Duration(seconds: 1));

  for (final note in const ['C4', 'G4', 'C5', 'E5']) {
    final hz = Note.parse(note).hz;
    print('Updating graph to note: $note (${hz.toStringAsFixed(1)} Hz)...');
    setGraph(hz);
    await Future.delayed(const Duration(seconds: 1));
  }

  // Stop playback and cleanly close ffplay
  await host.stopPlayback();
  await output.close();
  await host.dispose();

  print('Playback finished.');
}
