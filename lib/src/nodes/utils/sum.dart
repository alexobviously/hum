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
    implements AudioNode<SumProcessor> {
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
}

class SumProcessor implements AudioProcessor {
  final int numInputs;

  SumProcessor({required this.numInputs});

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

    final in1 = inputs[1];

    // TODO: SIMD

    if (numInputs == 2) {
      for (int i = 0; i < length; i++) {
        out[i] = in0[i] + in1[i];
      }
      return;
    }

    // 3 or more inputs: seed with the first two, then accumulate
    for (int i = 0; i < length; i++) {
      out[i] = in0[i] + in1[i];
    }

    for (int c = 2; c < numInputs; c++) {
      final inC = inputs[c];
      for (int i = 0; i < length; i++) {
        out[i] += inC[i];
      }
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
