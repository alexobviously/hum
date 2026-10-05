import 'dart:typed_data';

import 'package:dsp/src/core/audio_node.dart';
import 'package:dsp/src/core/audio_port.dart';
import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/process_context.dart';

class Gain implements AudioNode<GainProcessor> {
  final double gain;
  @override
  final List<AudioPort> inputs;

  const Gain({required this.gain, required this.inputs});

  factory Gain.mono({required double gain, required AudioPort input}) =>
      Gain(gain: gain, inputs: [input]);

  factory Gain.stereo({
    required double gain,
    required AudioPort leftInput,
    required AudioPort rightInput,
  }) => Gain(gain: gain, inputs: [leftInput, rightInput]);

  @override
  List<AudioPort> get outputs =>
      List.generate(inputs.length, (i) => AudioPort(node: this, index: i));

  @override
  GainProcessor createProcessor() =>
      GainProcessor(gain: gain, channels: inputs.length);

  @override
  void updateProcessor(GainProcessor processor) {
    processor.gain = gain;
  }
}

class GainProcessor implements AudioProcessor {
  final int channels;
  GainProcessor({required this.gain, required this.channels});

  double gain = 1.0;

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    for (int c = 0; c < channels; c++) {
      final output = outputs[c];
      for (int i = 0; i < context.vectorSize; i++) {
        output[i] = inputs[c][i] * gain;
      }
    }
  }
}
