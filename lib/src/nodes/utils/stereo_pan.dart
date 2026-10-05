import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsp/src/core/audio_node.dart';
import 'package:dsp/src/core/audio_port.dart';
import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/process_context.dart';

class StereoPan implements AudioNode<StereoPanProcessor> {
  final AudioPort input;

  /// Pan position from 0.0 (hard left) to 1.0 (hard right). 0.5 is centre.
  final double pan;

  const StereoPan({required this.input, this.pan = 0.5});

  AudioPort get left => AudioPort(node: this, index: 0);
  AudioPort get right => AudioPort(node: this, index: 1);

  @override
  List<AudioPort> get inputs => [input];

  @override
  List<AudioPort> get outputs => [left, right];

  @override
  StereoPanProcessor createProcessor() => StereoPanProcessor(pan: pan);

  @override
  void updateProcessor(StereoPanProcessor processor) {
    processor.pan = pan;
  }
}

class StereoPanProcessor implements AudioProcessor {
  StereoPanProcessor({required this.pan});

  /// Pan position from 0.0 (hard left) to 1.0 (hard right).
  double pan;

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final inBuf = inputs[0];
    final outLeft = outputs[0];
    final outRight = outputs[1];

    // Pan with equal-power pan law (-3dB centre).
    final clampedPan = pan.clamp(0.0, 1.0);
    final angle = clampedPan * (math.pi / 2);
    final leftGain = math.cos(angle);
    final rightGain = math.sin(angle);

    for (int i = 0; i < context.vectorSize; i++) {
      final sample = inBuf[i];
      outLeft[i] = sample * leftGain;
      outRight[i] = sample * rightGain;
    }
  }
}
