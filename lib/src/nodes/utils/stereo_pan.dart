import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsp/dsp.dart';

class StereoPan implements AudioNode<StereoPanProcessor> {
  final AudioPort input;

  /// Pan position from -1.0 (hard left) to +1.0 (hard right). 0.0 is centre.
  final ControlParam<double> pan;

  const StereoPan({
    required this.input,
    this.pan = const ControlParam.value(0.0),
  });

  AudioPort get left => AudioPort(node: this, index: 0);
  AudioPort get right => AudioPort(node: this, index: 1);

  @override
  List<AudioPort> get inputs => [
    input,
    if (pan case ControlParamSignal(:final port)) port,
  ];

  @override
  List<AudioPort> get outputs => [left, right];

  @override
  StereoPanProcessor createProcessor() => StereoPanProcessor(
    pan: switch (pan) {
      ControlParamValue(:final value) => value,
      ControlParamSignal() => null,
    },
  );

  @override
  void updateProcessor(StereoPanProcessor processor) {
    processor.pan = switch (pan) {
      ControlParamValue(:final value) => value,
      ControlParamSignal() => null,
    };
  }
}

class StereoPanProcessor implements AudioProcessor {
  StereoPanProcessor({required this.pan});

  /// Pan position from -1.0 (hard left) to +1.0 (hard right), or null if signal modulated.
  double? pan;

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final inBuf = inputs[0];
    final outLeft = outputs[0];
    final outRight = outputs[1];
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
      final panBuffer = inputs[1];

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
