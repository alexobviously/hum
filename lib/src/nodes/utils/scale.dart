import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef ScaleParams = ({
  double inLow,
  double inHigh,
  double outLow,
  double outHigh,
});

class Scale implements AudioNode<ScaleProcessor> {
  final Outlet input;
  final ControlParamValue<double> inLow;
  final ControlParamValue<double> inHigh;
  final ControlParamValue<double> outLow;
  final ControlParamValue<double> outHigh;

  Scale({
    required this.input,
    required this.inLow,
    required this.inHigh,
    required this.outLow,
    required this.outHigh,
  });

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
  ScaleParams get params => (
    inLow: inLow.value,
    inHigh: inHigh.value,
    outLow: outLow.value,
    outHigh: outHigh.value,
  );

  @override
  ScaleProcessor createProcessor() => ScaleProcessor(
    inLow: inLow.value,
    inHigh: inHigh.value,
    outLow: outLow.value,
    outHigh: outHigh.value,
  );
}

class ScaleProcessor implements AudioProcessor {
  ScaleProcessor({
    required this.inLow,
    required this.inHigh,
    required this.outLow,
    required this.outHigh,
  });

  double inLow;
  double inHigh;
  double outLow;
  double outHigh;

  @override
  void update(Object params) {
    params = params as ScaleParams;
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
