import 'dart:io';

import 'package:hum/hum.dart';

AudioNode _graph(double frequency) {
  final osc = SineOscillator(frequency: .value(frequency));
  final gain = Mult.mono(input: osc.outlet, value: const .value(0.2));

  return Dac.stereo(left: gain.outlet, right: gain.outlet);
}

void main() async {
  const sampleRate = 44100;
  const vectorSize = 64;
  final context = ProcessContext(
    sampleRate: sampleRate,
    vectorSize: vectorSize,
  );

  // Initialize AudioHost and compile the declarative graph
  final host = await AudioHost.spawn(context: context);

  void setGraph(double frequency) {
    final diagnostics = host.setGraph(root: _graph(440));
    if (diagnostics.isNotEmpty) {
      stderr.writeln('Graph compilation failed: $diagnostics');
      return;
    }
    // DOESN'T WORK YET, DEBUGGING, NEED TO COMMIT FIRST
  }

  setGraph(440);

  // Create ffplay audio output destination
  final output = await PipedAudioOutput.ffplay(
    numChannels: 2,
    vectorSize: vectorSize,
    sampleRate: sampleRate,
  );

  print('Playing 440 Hz sine wave via ffplay for 3 seconds...');
  print('Press Ctrl+C to abort.');

  // Start real-time playback engine with backpressure
  await host.startPlayback(output);

  // Stream for 3 seconds
  await Future.delayed(const Duration(seconds: 3));

  for (final note in const ['C4', 'G4', 'C5', 'E5']) {
    final hz = Note.parse(note).hz;
    setGraph(hz);
    await Future.delayed(const Duration(seconds: 1));
  }

  // Stop playback and cleanly close ffplay
  await host.stopPlayback();
  await output.close();
  await host.dispose();

  print('Playback finished.');
}
