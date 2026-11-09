import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef SumParams = ();

/// An [AudioNode] that computes the linear sum of multiple input [Outlet]s.
///
/// Output at sample `i` is:
/// `out[i] = in0[i] + in1[i] + ... + inN[i]`
///
/// If no inputs are provided, the output buffer is filled with silence (0.0).
class Sum({required final List<Outlet> inputs})
    extends AudioNode<SumProcessor> {
  /// Convenience constructor to sum two outlets.
  factory pair(Outlet a, Outlet b) => Sum(inputs: [a, b]);

  /// Convenience constructor to sum a list of outlets.
  factory of(List<Outlet> inputs) => Sum(inputs: inputs);

  @override
  List<Inlet> get inlets => List.generate(
    inputs.length,
    (i) => Inlet(node: this, index: i, source: inputs[i]),
  );

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;

  @override
  SumProcessor createProcessor() => SumProcessor(numInputs: inputs.length);

  @override
  SumParams get params => ();

  @override
  List<AudioNodeError> get errors => [
    if (inputs.isEmpty)
      const AudioNodeParamError(param: 'inputs', error: 'must not be empty'),
  ];

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => const [];
}

class SumProcessor implements AudioProcessor {
  final int numInputs;

  SumProcessor({required this.numInputs});

  // Cached SIMD vector views
  Float32List? _lastOut;
  Float32x4List? _out4;
  List<Float32x4List>? _in4;

  @override
  void update(Object params) {}

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final out = outputs[0];
    final length = context.vectorSize;

    if (numInputs == 0) {
      out.fillRange(0, length, 0.0);
      return;
    }

    final in0 = inputs[0];

    if (numInputs == 1) {
      out.setRange(0, length, in0);
      return;
    }

    final simdLength = length ~/ 4;
    final tailStart = simdLength * 4;

    if (simdLength > 0) {
      // lazy initialisation, happens in first block
      if (!identical(_lastOut, out)) {
        _lastOut = out;
        _out4 = out.buffer.asFloat32x4List(out.offsetInBytes, simdLength);
        _in4 = [
          for (int c = 0; c < numInputs; c++)
            inputs[c].buffer.asFloat32x4List(
              inputs[c].offsetInBytes,
              simdLength,
            ),
        ];
      }

      final out4 = _out4!;
      final in4 = _in4!;

      // This is just an optimisation to avoid needlessly 'zeroing' the buffer.
      _addPair(out4, in4[0], in4[1], simdLength);

      for (int c = 2; c < numInputs; c++) {
        _accumulate(out4, in4[c], simdLength);
      }

      // Another, slightly less efficient, way to write this would be
      //
      // out.fillRange(0, length, 0.0); // Wasted pass: writes 64 zeros to memory
      // for (int c = 0; c < numInputs; c++) {
      //   out[i] += inputs[c][i];
      // }
    }

    if (tailStart < length) {
      final in1 = inputs[1];
      for (int i = tailStart; i < length; i++) {
        out[i] = in0[i] + in1[i];
      }
      for (int c = 2; c < numInputs; c++) {
        final inC = inputs[c];
        for (int i = tailStart; i < length; i++) {
          out[i] += inC[i];
        }
      }
    }
  }

  /// Inlined static helper guarantees the Dart JIT unboxes SIMD registers
  /// without boxing.
  @pragma('vm:prefer-inline')
  static void _addPair(
    Float32x4List out,
    Float32x4List a,
    Float32x4List b,
    int len,
  ) {
    for (int i = 0; i < len; i++) {
      out[i] = a[i] + b[i];
    }
  }

  @pragma('vm:prefer-inline')
  static void _accumulate(Float32x4List out, Float32x4List a, int len) {
    for (int i = 0; i < len; i++) {
      out[i] = out[i] + a[i];
    }
  }
}

/// Extension on [Outlet] allowing natural `+` operator syntax for summing signals.
extension OutletSumExtension on Outlet {
  /// Returns a new [Outlet] that is the sum of `this` and [other].
  Outlet operator +(Outlet other) => Sum.pair(this, other).outlet;
}

extension OutletListSumExtension on List<Outlet> {
  /// Returns a [Sum] node that combines all the outlets in the list.
  Sum get sum => Sum(inputs: this);
}
