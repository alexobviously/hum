import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef StereoPanParams = ({double? pan});

class StereoPan extends AudioNode<StereoPanProcessor> {
  final Outlet input;

  /// Pan position from -1.0 (hard left) to +1.0 (hard right). 0.0 is centre.
  final ControlParam<double> pan;

  const StereoPan({
    required this.input,
    this.pan = const ControlParam.value(0.0),
  });

  static const inputInlet = 0;
  static const panInlet = 1;
  static const leftOutlet = 0;
  static const rightOutlet = 1;

  Outlet get left => outlets[leftOutlet];
  Outlet get right => outlets[rightOutlet];

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: inputInlet, source: input),
    Inlet(node: this, index: panInlet, source: pan.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: leftOutlet),
    Outlet(node: this, index: rightOutlet),
  ];

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [pan];

  @override
  StereoPanProcessor createProcessor() =>
      StereoPanProcessor(pan: pan.valueOrNull);

  @override
  StereoPanParams get params => (pan: pan.valueOrNull);
}

class StereoPanProcessor implements AudioProcessor {
  StereoPanProcessor({required this.pan});

  /// Pan position from -1.0 (hard left) to +1.0 (hard right), or null if signal modulated.
  double? pan;

  @override
  void update(Object params) {
    params = params as StereoPanParams;
    pan = params.pan;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final inBuf = inputs[StereoPan.inputInlet];
    final outLeft = outputs[StereoPan.leftOutlet];
    final outRight = outputs[StereoPan.rightOutlet];
    final pan = this.pan;

    if (pan != null) {
      final (leftGain, rightGain) = equalPowerGains(pan);

      for (int i = 0; i < context.vectorSize; i++) {
        final sample = inBuf[i];
        outLeft[i] = sample * leftGain;
        outRight[i] = sample * rightGain;
      }
    } else {
      final panBuffer = inputs[StereoPan.panInlet];

      for (int i = 0; i < context.vectorSize; i++) {
        final sample = inBuf[i];
        final (leftGain, rightGain) = equalPowerGains(panBuffer[i]);
        outLeft[i] = sample * leftGain;
        outRight[i] = sample * rightGain;
      }
    }
  }
}
