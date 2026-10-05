import 'dart:typed_data';

import 'package:dsp/src/core/audio_node.dart';
import 'package:dsp/src/core/audio_port.dart';
import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/process_context.dart';

class Dac implements AudioNode<DacProcessor> {
  @override
  final List<AudioPort> inputs;
  const Dac({required this.inputs});

  @override
  List<AudioPort> get outputs => [];

  @override
  DacProcessor createProcessor() => DacProcessor();

  @override
  void updateProcessor(DacProcessor processor) {}
}

class DacProcessor implements AudioProcessor {
  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    // no-op
  }
}
