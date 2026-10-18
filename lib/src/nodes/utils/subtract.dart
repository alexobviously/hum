import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef SubtractParams = ({double? value});

/// An [AudioNode] that subtracts a [value] from incoming audio [channels].
///
/// Output calculation: `out = input - value`.
///
/// - If [value] is a static number, this subtracts a constant offset.
/// - If [value] is an [Outlet], this performs audio-rate vector subtraction
///   (`input[i] - value[i]`), ideal for phase inversion cancellation, Mid/Side
///   decoding (`Left - Right = Side`), or differential signal analysis.
///
/// You could also just use [Add] and [Invert], but this is nicer.
class const Subtract({
  required final ControlParam<double> value,
  required final List<Outlet> channels,
}) implements AudioNode<SubtractProcessor> {
  factory mono({
    required ControlParam<double> value,
    required Outlet input,
  }) => Subtract(value: value, channels: [input]);

  factory stereo({
    required ControlParam<double> value,
    required Outlet leftInput,
    required Outlet rightInput,
  }) => Subtract(value: value, channels: [leftInput, rightInput]);

  static const valueInlet = 0;
  static const audioInletOffset = 1;

  int get numChannels => channels.length;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: valueInlet, source: value.outletOrNull),
    ...List.generate(
      channels.length,
      (i) =>
          Inlet(node: this, index: audioInletOffset + i, source: channels[i]),
    ),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(channels.length, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  SubtractProcessor createProcessor() => SubtractProcessor(
    value: value.valueOrNull,
    numChannels: channels.length,
  );

  @override
  SubtractParams get params => (value: value.valueOrNull);
}

class SubtractProcessor({
  var double? value,
  required final int numChannels,
}) implements AudioProcessor {
  @override
  void update(Object params) {
    params = params as SubtractParams;
    value = params.value;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final v = value;

    if (v != null) {
      // scalar
      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];
        final input = inputs[c + Subtract.audioInletOffset];

        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = input[i] - v;
        }
      }
    } else {
      // signal
      final valueBuffer = inputs[Subtract.valueInlet];

      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];
        final input = inputs[c + Subtract.audioInletOffset];

        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = input[i] - valueBuffer[i];
        }
      }
    }
  }
}

extension OutletSubtractExtension on Outlet {
  /// Subtracts [other] signal from this outlet: `this - other`.
  Outlet operator -(Outlet other) =>
      Subtract.mono(input: this, value: .signal(other)).outlet;

  /// Subtracts a constant scalar [value] from this outlet.
  Subtract subtract(double value) =>
      Subtract.mono(input: this, value: .value(value));
}
