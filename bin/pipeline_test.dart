import 'dart:typed_data';

import 'package:dsp/dsp.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const blocks = sr ~/ vs; // one second
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final sine = SineOscillator(frequency: 440);
  final gain = Gain.mono(gain: 0.7, input: sine.output);
  final pan = StereoPan(input: gain.outputs.first, pan: 0.3);
  final dac = Dac(inputs: pan.outputs);
  final pipeline = compilePipeline(root: dac, context: context);

  final audio = <Float32List>[];
  for (int i = 0; i < blocks; i++) {
    pipeline.process();
    final left = pipeline.outputs[0];
    final right = pipeline.outputs[1];
    // Fresh buffer + sample-by-sample interleaving:
    final interleaved = Float32List(vs * 2);
    for (int s = 0; s < vs; s++) {
      interleaved[s * 2] = left[s];
      interleaved[s * 2 + 1] = right[s];
    }
    audio.add(interleaved);
  }

  writeWav('pipeline_test.wav', audio, numChannels: 2);
}
