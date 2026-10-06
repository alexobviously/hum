import 'dart:typed_data';

import 'package:dsp/dsp.dart';

class Gain implements AudioNode<GainProcessor> {
  final ControlParam<double> gain;
  final List<AudioPort> channels;

  const Gain({required this.gain, required this.channels});

  factory Gain.mono({
    required ControlParam<double> gain,
    required AudioPort input,
  }) => Gain(gain: gain, channels: [input]);

  factory Gain.stereo({
    required ControlParam<double> gain,
    required AudioPort leftInput,
    required AudioPort rightInput,
  }) => Gain(gain: gain, channels: [leftInput, rightInput]);

  @override
  List<AudioPort> get inputs => [
    ...channels,
    if (gain case ControlParamSignal(:final port)) port,
  ];

  @override
  List<AudioPort> get outputs =>
      List.generate(channels.length, (i) => AudioPort(node: this, index: i));

  @override
  GainProcessor createProcessor() => GainProcessor(
    gain: switch (gain) {
      ControlParamValue(:final value) => value,
      ControlParamSignal() => null,
    },
    numChannels: channels.length,
  );

  @override
  void updateProcessor(GainProcessor processor) {
    processor.gain = switch (gain) {
      ControlParamValue(:final value) => value,
      ControlParamSignal() => null,
    };
  }
}

class GainProcessor implements AudioProcessor {
  final int numChannels;
  GainProcessor({required this.gain, required this.numChannels});

  double? gain;

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final gain = this.gain;

    if (gain != null) {
      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];

        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = inputs[c][i] * gain;
        }
      }
    } else {
      final gainBuffer = inputs[inputs.length - 1];

      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];

        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = inputs[c][i] * gainBuffer[i];
        }
      }
    }
  }
}
