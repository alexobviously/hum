import 'dart:typed_data';

import 'package:hum/hum.dart';

class StereoSplit extends AudioNode<StereoSplitProcessor> {
  final Outlet input;

  const StereoSplit({required this.input});

  static const inputInlet = 0;
  static const leftOutlet = 0;
  static const rightOutlet = 1;

  Outlet get left => outlets[leftOutlet];
  Outlet get right => outlets[rightOutlet];

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: inputInlet, source: input),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: leftOutlet),
    Outlet(node: this, index: rightOutlet),
  ];

  @override
  StereoSplitProcessor createProcessor() => StereoSplitProcessor();

  @override
  Object get params => ();
}

class StereoSplitProcessor implements AudioProcessor {
  StereoSplitProcessor();

  @override
  void update(Object params) {}

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final inBuf = inputs[StereoSplit.inputInlet];
    final outLeft = outputs[StereoSplit.leftOutlet];
    final outRight = outputs[StereoSplit.rightOutlet];

    for (int i = 0; i < context.vectorSize; i++) {
      final sample = inBuf[i];
      outLeft[i] = sample;
      outRight[i] = sample;
    }
  }
}
