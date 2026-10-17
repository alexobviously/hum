import 'dart:typed_data';

import 'package:dsp/src/core/process_context.dart';
import 'package:dsp/src/io/wav_writer.dart';
import 'package:dsp/src/nodes/oscillators/sine_oscillator.dart';
import 'package:dsp/src/nodes/utils/mult.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const numBlocks = sr ~/ vs; // 1 second
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final sine = SineOscillator(frequency: .value(440));
  final mult = Mult.mono(value: .value(0.5), input: sine.outlet);
  final sineProcessor = sine.createProcessor();
  final multProcessor = mult.createProcessor();

  final audio = <Float32List>[];
  for (int i = 0; i < numBlocks; i++) {
    final bufA = Float32List(vs);
    final bufB = Float32List(vs);
    sineProcessor.process(context, [], [bufA]);
    multProcessor.process(context, [bufA], [bufB]);
    audio.add(bufB);
  }

  writeWav('sine.wav', audio);
}
