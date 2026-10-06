import 'dart:typed_data';

import 'package:dsp/dsp.dart';

class Offset implements AudioNode<OffsetProcessor> {
  final ControlParam<double> value;
  final List<AudioPort> channels;

  const Offset({required this.value, required this.channels});

  factory Offset.mono({
    required ControlParam<double> value,
    required AudioPort input,
  }) => Offset(value: value, channels: [input]);

  factory Offset.stereo({
    required ControlParam<double> value,
    required AudioPort leftInput,
    required AudioPort rightInput,
  }) => Offset(value: value, channels: [leftInput, rightInput]);

  @override
  List<AudioPort> get inputs => [
    ...channels,
    if (value case ControlParamSignal(:final port)) port,
  ];

  @override
  List<AudioPort> get outputs =>
      List.generate(channels.length, (i) => AudioPort(node: this, index: i));

  @override
  OffsetProcessor createProcessor() => OffsetProcessor(
    value: switch (value) {
      ControlParamValue(:final value) => value,
      ControlParamSignal() => null,
    },
    numChannels: channels.length,
  );

  @override
  void updateProcessor(OffsetProcessor processor) {
    processor.value = switch (value) {
      ControlParamValue(:final value) => value,
      ControlParamSignal() => null,
    };
  }
}

class OffsetProcessor implements AudioProcessor {
  final int numChannels;
  OffsetProcessor({required this.value, required this.numChannels});

  double? value;

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final value = this.value;

    if (value != null) {
      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];
        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = inputs[c][i] + value;
        }
      }
    } else {
      final valueBuffer = inputs[inputs.length - 1];

      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];
        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = inputs[c][i] + valueBuffer[i];
        }
      }
    }
  }
}
