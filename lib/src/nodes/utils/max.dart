import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef MaxParams = ({double? value});

/// An [AudioNode] that computes the maximum between signals or thresholds (`out = max(a, b)`).
///
/// In modular synthesis, [Max] acts as an **Analog OR gate**:
/// - When combining gates or clock pulses, it outputs a pulse if either input is high.
/// - When combining audio signals or LFOs, it tracks the upper contour of both waveforms.
/// - When used with a static value (e.g. `0.0`), it functions as a half-wave rectifier.
class Max({
  required final List<Outlet> channels,
  final ControlParam<double>? value,
}) extends AudioNode<MaxProcessor> {
  /// Compares two input outlets sample-by-sample and outputs their maximum.
  factory pair(Outlet a, Outlet b) => Max(channels: [a, b]);

  /// Computes the sample-by-sample maximum across multiple input outlets.
  factory of(List<Outlet> inputs) => Max(channels: inputs);

  /// Compares a single audio [input] against a static or signal-modulated [value].
  factory mono(Outlet input, ControlParam<double> value) =>
      Max(channels: [input], value: value);

  /// Compares stereo audio inputs against a static or signal-modulated [value].
  factory stereo(
    Outlet leftInput,
    Outlet rightInput,
    ControlParam<double> value,
  ) => Max(channels: [leftInput, rightInput], value: value);

  static const valueInlet = 0;

  @override
  List<Inlet> get inlets => value != null
      ? [
          Inlet(node: this, index: valueInlet, source: value!.outletOrNull),
          ...List.generate(
            channels.length,
            (i) => Inlet(node: this, index: i + 1, source: channels[i]),
          ),
        ]
      : List.generate(
          channels.length,
          (i) => Inlet(node: this, index: i, source: channels[i]),
        );

  @override
  List<Outlet> get outlets => value != null
      ? List.generate(channels.length, (i) => Outlet(node: this, index: i))
      : [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  MaxProcessor createProcessor() => MaxProcessor(
    value: value?.valueOrNull,
    hasValue: value != null,
    numChannels: channels.length,
  );

  @override
  MaxParams get params => (value: value?.valueOrNull);

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeParamError(param: 'channels', error: 'must not be empty'),
  ];

  @override
  bool canUpdate(covariant Max newNode) =>
      super.canUpdate(newNode) &&
      value.canUpdate(newNode.value) &&
      channels.length == newNode.channels.length;
}

class MaxProcessor implements AudioProcessor {
  final bool hasValue;
  final int numChannels;
  double? value;

  MaxProcessor({
    required this.value,
    required this.hasValue,
    required this.numChannels,
  });

  @override
  void update(Object params) {
    value = (params as MaxParams).value;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;

    if (hasValue) {
      final v = value;
      if (v != null) {
        // Scalar value comparison
        for (int c = 0; c < numChannels; c++) {
          final inBuf = inputs[c + 1];
          final outBuf = outputs[c];
          for (int i = 0; i < length; i++) {
            final s = inBuf[i];
            outBuf[i] = s > v ? s : v;
          }
        }
      } else {
        // Signal-modulated value comparison
        final valBuf = inputs[Max.valueInlet];
        for (int c = 0; c < numChannels; c++) {
          final inBuf = inputs[c + 1];
          final outBuf = outputs[c];
          for (int i = 0; i < length; i++) {
            final s = inBuf[i];
            final thresh = valBuf[i];
            outBuf[i] = s > thresh ? s : thresh;
          }
        }
      }
    } else {
      // Multi-input Maximum across channels -> single output
      final out = outputs[0];

      if (numChannels == 0) {
        out.fillRange(0, length, 0.0);
        return;
      }

      final in0 = inputs[0];
      if (numChannels == 1) {
        out.setRange(0, length, in0);
        return;
      }

      final in1 = inputs[1];
      if (numChannels == 2) {
        for (int i = 0; i < length; i++) {
          final a = in0[i];
          final b = in1[i];
          out[i] = a > b ? a : b;
        }
        return;
      }

      // 3 or more inputs
      for (int i = 0; i < length; i++) {
        final a = in0[i];
        final b = in1[i];
        out[i] = a > b ? a : b;
      }

      for (int c = 2; c < numChannels; c++) {
        final inC = inputs[c];
        for (int i = 0; i < length; i++) {
          final s = inC[i];
          if (s > out[i]) {
            out[i] = s;
          }
        }
      }
    }
  }
}

extension OutletMaxExtension on Outlet {
  /// Computes the sample-by-sample maximum between `this` and [other].
  ///
  /// [other] can be an [Outlet], [ControlParam<double>], or a [num] scalar.
  Outlet max(dynamic other) {
    return switch (other) {
      final Outlet o => Max.pair(this, o).outlet,
      final ControlParam<double> p => Max.mono(this, p).outlet,
      final num n => Max.mono(this, ControlParam.value(n.toDouble())).outlet,
      _ => throw ArgumentError(
        'Unsupported operand for max: ${other.runtimeType}. Expected Outlet, ControlParam<double>, or num.',
      ),
    };
  }
}

extension OutletListMaxExtension on List<Outlet> {
  /// Returns a [Max] node computing the maximum across all outlets in this list.
  Max get max => Max.of(this);
}
