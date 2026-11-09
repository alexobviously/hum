import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef AddParams = ({double? value});

/// An [AudioNode] that adds a [value] to incoming audio [channels].
///
/// If [value] is a static number, this applies a constant DC offset.
/// If [value] is an [Outlet], this performs audio-rate vector addition.
class const Add({
  required final ControlParam<double> value,
  required final List<Outlet> channels,
}) extends AudioNode<AddProcessor> {
  factory mono({
    required ControlParam<double> value,
    required Outlet input,
  }) => Add(value: value, channels: [input]);

  factory stereo({
    required ControlParam<double> value,
    required Outlet leftInput,
    required Outlet rightInput,
  }) => Add(value: value, channels: [leftInput, rightInput]);

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
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [value];

  @override
  AddProcessor createProcessor() => AddProcessor(
    value: value.valueOrNull,
    numChannels: channels.length,
  );

  @override
  AddParams get params => (value: value.valueOrNull);
}

class AddProcessor implements AudioProcessor {
  final int numChannels;
  AddProcessor({required this.value, required this.numChannels});

  double? value;

  @override
  void update(Object params) {
    params = params as AddParams;
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
          output[i] = input[i] + value;
        }
      }
    } else {
      final valueBuffer = inputs[Add.valueInlet];

      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];
        final input = inputs[c + 1];

        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = input[i] + valueBuffer[i];
        }
      }
    }
  }
}
