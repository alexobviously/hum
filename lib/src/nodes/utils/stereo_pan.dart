import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsp/dsp.dart';

typedef StereoPanParams = ({double? pan});

class StereoPan implements AudioNode<StereoPanProcessor> {
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
      final clampedPan = pan.clamp(-1.0, 1.0);
      final angle = (clampedPan + 1.0) * (math.pi / 4);
      final leftGain = math.cos(angle);
      final rightGain = math.sin(angle);

      for (int i = 0; i < context.vectorSize; i++) {
        final sample = inBuf[i];
        outLeft[i] = sample * leftGain;
        outRight[i] = sample * rightGain;
      }
    } else {
      final panBuffer = inputs[StereoPan.panInlet];

      for (int i = 0; i < context.vectorSize; i++) {
        final sample = inBuf[i];
        final clampedPan = panBuffer[i].clamp(-1.0, 1.0);
        final angle = (clampedPan + 1.0) * (math.pi / 4);
        outLeft[i] = sample * math.cos(angle);
        outRight[i] = sample * math.sin(angle);
      }
    }
  }
}
