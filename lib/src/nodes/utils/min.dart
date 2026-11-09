import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef MinParams = ({double? value});

/// An [AudioNode] that computes the minimum between signals or thresholds (`out = min(a, b)`).
///
/// In modular synthesis, [Min] acts as an **Analog AND gate**:
/// - When combining gates or clock pulses, it outputs a pulse only when both inputs are high.
/// - When combining audio signals or LFOs, it tracks the lower contour of both waveforms.
/// - When used with a static value (e.g. `0.0`), it cuts off all positive excursions.
class Min({
  required final List<Outlet> channels,
  final ControlParam<double>? value,
}) extends AudioNode<MinProcessor> {
  /// Compares two input outlets sample-by-sample and outputs their minimum.
  factory pair(Outlet a, Outlet b) => Min(channels: [a, b]);

  /// Computes the sample-by-sample minimum across multiple input outlets.
  factory of(List<Outlet> inputs) => Min(channels: inputs);

  /// Compares a single audio [input] against a static or signal-modulated [value].
  factory mono(Outlet input, ControlParam<double> value) =>
      Min(channels: [input], value: value);

  /// Compares stereo audio inputs against a static or signal-modulated [value].
  factory stereo(
    Outlet leftInput,
    Outlet rightInput,
    ControlParam<double> value,
  ) => Min(channels: [leftInput, rightInput], value: value);

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
  MinProcessor createProcessor() => MinProcessor(
    value: value?.valueOrNull,
    hasValue: value != null,
    numChannels: channels.length,
  );

  @override
  MinParams get params => (value: value?.valueOrNull);

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeParamError(param: 'channels', error: 'must not be empty'),
  ];

  @override
  List<Object?> get fixedProps => [
    value != null,
    value?.isSignal,
  ];

  @override
  List<Object?> get dynamicProps => [value];
}

class MinProcessor implements AudioProcessor {
  final bool hasValue;
  final int numChannels;
  double? value;

  MinProcessor({
    required this.value,
    required this.hasValue,
    required this.numChannels,
  });

  @override
  void update(Object params) {
    value = (params as MinParams).value;
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
            outBuf[i] = s < v ? s : v;
          }
        }
      } else {
        // Signal-modulated value comparison
        final valBuf = inputs[Min.valueInlet];
        for (int c = 0; c < numChannels; c++) {
          final inBuf = inputs[c + 1];
          final outBuf = outputs[c];
          for (int i = 0; i < length; i++) {
            final s = inBuf[i];
            final thresh = valBuf[i];
            outBuf[i] = s < thresh ? s : thresh;
          }
        }
      }
    } else {
      // Multi-input Minimum across channels -> single output
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
          out[i] = a < b ? a : b;
        }
        return;
      }

      // 3 or more inputs
      for (int i = 0; i < length; i++) {
        final a = in0[i];
        final b = in1[i];
        out[i] = a < b ? a : b;
      }

      for (int c = 2; c < numChannels; c++) {
        final inC = inputs[c];
        for (int i = 0; i < length; i++) {
          final s = inC[i];
          if (s < out[i]) {
            out[i] = s;
          }
        }
      }
    }
  }
}

extension OutletMinExtension on Outlet {
  /// Computes the sample-by-sample minimum between `this` and [other].
  ///
  /// [other] can be an [Outlet], [ControlParam<double>], or a [num] scalar.
  Outlet min(dynamic other) {
    return switch (other) {
      final Outlet o => Min.pair(this, o).outlet,
      final ControlParam<double> p => Min.mono(this, p).outlet,
      final num n => Min.mono(this, ControlParam.value(n.toDouble())).outlet,
      _ => throw ArgumentError(
        'Unsupported operand for min: ${other.runtimeType}. Expected Outlet, ControlParam<double>, or num.',
      ),
    };
  }
}

extension OutletListMinExtension on List<Outlet> {
  /// Returns a [Min] node computing the minimum across all outlets in this list.
  Min get min => Min.of(this);
}
