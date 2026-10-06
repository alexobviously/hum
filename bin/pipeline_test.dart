import 'dart:typed_data';

import 'package:dsp/dsp.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const blocks = sr * 5 ~/ vs; // 5 seconds
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final lfo = SineOscillator(frequency: .value(5));
  final lfo2 = SineOscillator(frequency: .value(1));
  final depth = Gain.mono(gain: .value(25), input: lfo.output); // ±25 Hz
  final pitch = Offset.mono(
    value: .value(440),
    input: depth.outputs.first,
  ); // 440 ± 25 Hz
  final carrier = SineOscillator(frequency: .signal(pitch.outputs.first));
  final gain = Gain.mono(gain: .value(0.7), input: carrier.output);

  final pan = StereoPan(
    input: gain.outputs.first,
    pan: .signal(lfo2.outputs.first),
  );
  final dac = Dac(inputs: pan.outputs);
  final pipeline = compilePipeline(root: dac, context: context);

  final audio = <Float32List>[];
  for (int i = 0; i < blocks; i++) {
    pipeline.process();
    final left = pipeline.outputs[0];
    final right = pipeline.outputs[1];
    final interleaved = Float32List(vs * 2);
    for (int s = 0; s < vs; s++) {
      interleaved[s * 2] = left[s];
      interleaved[s * 2 + 1] = right[s];
    }
    audio.add(interleaved);
  }

  writeWav('pipeline_test2.wav', audio, numChannels: 2);
}
