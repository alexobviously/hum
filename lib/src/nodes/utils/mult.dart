import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef MultParams = ({double? value});

/// An [AudioNode] that multiplies incoming audio [channels] by a [value].
///
/// If [value] is a static number, this scales the signal amplitude.
/// If [value] is an [Outlet], this performs audio-rate vector multiplication
/// (4-quadrant ring modulation / amplitude modulation).
class const Mult({
  required final ControlParam<double> value,
  required final List<Outlet> channels,
}) extends AudioNode<MultProcessor> {
  factory mono({
    required ControlParam<double> value,
    required Outlet input,
  }) => Mult(value: value, channels: [input]);

  factory stereo({
    required ControlParam<double> value,
    required Outlet leftInput,
    required Outlet rightInput,
  }) => Mult(value: value, channels: [leftInput, rightInput]);

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
  MultProcessor createProcessor() => MultProcessor(
    value: value.valueOrNull,
    numChannels: channels.length,
  );

  @override
  MultParams get params => (value: value.valueOrNull);
}

class MultProcessor implements AudioProcessor {
  final int numChannels;
  MultProcessor({required this.value, required this.numChannels});

  double? value;

  @override
  void update(Object params) {
    params = params as MultParams;
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
        final input = inputs[c + 1];

        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = input[i] * value;
        }
      }
    } else {
      final multBuffer = inputs[Mult.valueInlet];

      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];
        final input = inputs[c + 1];

        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = input[i] * multBuffer[i];
        }
      }
    }
  }
}
