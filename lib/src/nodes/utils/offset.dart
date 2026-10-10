import 'dart:typed_data';

import 'package:dsp/dsp.dart';

typedef OffsetParams = ({double? value});

/// Takes an input and adds a [value] to it.
class Offset implements AudioNode<OffsetProcessor> {
  final ControlParam<double> value;
  final List<Outlet> channels;

  const Offset({required this.value, required this.channels});

  factory Offset.mono({
    required ControlParam<double> value,
    required Outlet input,
  }) => Offset(value: value, channels: [input]);

  factory Offset.stereo({
    required ControlParam<double> value,
    required Outlet leftInput,
    required Outlet rightInput,
  }) => Offset(value: value, channels: [leftInput, rightInput]);

  static const valueInlet = 0;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: valueInlet, source: value.outletOrNull),
    ...List.generate(
      channels.length,
      (i) => Inlet(node: this, index: i + 1, source: channels[i]),
    ),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(channels.length, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;

  @override
  OffsetProcessor createProcessor() => OffsetProcessor(
    value: switch (value) {
      ControlParamValue(:final value) => value,
      ControlParamSignal() => null,
    },
    numChannels: channels.length,
  );

  @override
  OffsetParams get params => (value: value.valueOrNull);
}

class OffsetProcessor implements AudioProcessor {
  final int numChannels;
  OffsetProcessor({required this.value, required this.numChannels});

  double? value;

  @override
  void update(Object params) {
    params = params as OffsetParams;
    value = params.value;
  }

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
          output[i] = inputs[c + 1][i] + value;
        }
      }
    } else {
      final valueBuffer = inputs[Offset.valueInlet];

      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];
        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = inputs[c + 1][i] + valueBuffer[i];
        }
      }
    }
  }
}
