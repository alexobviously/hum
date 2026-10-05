import 'dart:typed_data';

import 'package:dsp/src/core/audio_node.dart';
import 'package:dsp/src/core/audio_port.dart';
import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/process_context.dart';

class StereoSplit implements AudioNode<StereoSplitProcessor> {
  final AudioPort input;

  const StereoSplit({required this.input});

  AudioPort get left => AudioPort(node: this, index: 0);
  AudioPort get right => AudioPort(node: this, index: 1);

  @override
  List<AudioPort> get inputs => [input];

  @override
  List<AudioPort> get outputs => [left, right];

  @override
  StereoSplitProcessor createProcessor() => StereoSplitProcessor();

  @override
  void updateProcessor(StereoSplitProcessor processor) {}
}

class StereoSplitProcessor implements AudioProcessor {
  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final inBuf = inputs[0];
    final outLeft = outputs[0];
    final outRight = outputs[1];

    for (int i = 0; i < context.vectorSize; i++) {
      final sample = inBuf[i];
      outLeft[i] = sample;
      outRight[i] = sample;
    }
  }
}
