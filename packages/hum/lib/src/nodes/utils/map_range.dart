import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef MapRangeParams = ({
  double inLow,
  double inHigh,
  double outLow,
  double outHigh,
});

/// Linearly maps an audio signal from input range `[inLow, inHigh]` to
/// output range `[outLow, outHigh]`.
///
/// Formula: `out = (in - inLow) * ((outHigh - outLow) / (inHigh - inLow)) + outLow`.
class MapRange({
  required final Outlet input,
  required final ControlParamValue<double> inLow,
  required final ControlParamValue<double> inHigh,
  required final ControlParamValue<double> outLow,
  required final ControlParamValue<double> outHigh,
}) extends AudioNode<MapRangeProcessor> {
  /// Convenience constructor for remapping a standard bipolar signal `[-1.0, +1.0]`
  /// (e.g. from an oscillator or LFO) to `[outLow, outHigh]`.
  factory bipolar({
    required Outlet input,
    required double outLow,
    required double outHigh,
  }) => MapRange(
    input: input,
    inLow: const .value(-1.0),
    inHigh: const .value(1.0),
    outLow: .value(outLow),
    outHigh: .value(outHigh),
  );

  /// Convenience constructor for remapping a unipolar signal `[0.0, 1.0]`
  /// (e.g. from an envelope or gate) to `[outLow, outHigh]`.
  factory unipolar({
    required Outlet input,
    required double outLow,
    required double outHigh,
  }) => MapRange(
    input: input,
    inLow: const .value(0.0),
    inHigh: const .value(1.0),
    outLow: .value(outLow),
    outHigh: .value(outHigh),
  );

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: 0, source: input),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: 0),
  ];

  Outlet get outlet => outlets.first;

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [inLow, inHigh, outLow, outHigh];

  @override
  MapRangeParams get params => (
    inLow: inLow.value,
    inHigh: inHigh.value,
    outLow: outLow.value,
    outHigh: outHigh.value,
  );

  @override
  MapRangeProcessor createProcessor() => MapRangeProcessor(
    inLow: inLow.value,
    inHigh: inHigh.value,
    outLow: outLow.value,
    outHigh: outHigh.value,
  );
}

class MapRangeProcessor({
  required var double inLow,
  required var double inHigh,
  required var double outLow,
  required var double outHigh,
}) implements AudioProcessor {
  @override
  void update(Object params) {
    params = params as MapRangeParams;
    inLow = params.inLow;
    inHigh = params.inHigh;
    outLow = params.outLow;
    outHigh = params.outHigh;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final input = inputs[0];
    final output = outputs[0];

    final inRange = inHigh - inLow;
    final scaleFactor = inRange != 0.0 ? (outHigh - outLow) / inRange : 0.0;

    for (int i = 0; i < context.vectorSize; i++) {
      output[i] = (input[i] - inLow) * scaleFactor + outLow;
    }
  }
}

/// Extension on [Outlet] to remap ranges fluidly.
extension OutletMapRangeExtension on Outlet {
  /// Linearly remaps this outlet's signal from `[inLow, inHigh]` to `[outLow, outHigh]`.
  MapRange mapRange(
    double outLow,
    double outHigh, {
    double inLow = -1.0,
    double inHigh = 1.0,
  }) => MapRange(
    input: this,
    inLow: .value(inLow),
    inHigh: .value(inHigh),
    outLow: .value(outLow),
    outHigh: .value(outHigh),
  );
}
