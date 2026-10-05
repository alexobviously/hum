import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsp/src/core/audio_node.dart';
import 'package:dsp/src/core/audio_port.dart';
import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/process_context.dart';

class SineOscillator implements AudioNode<SineOscillatorProcessor> {
  final double frequency;
  const SineOscillator({required this.frequency});

  AudioPort get output => AudioPort(node: this, index: 0);

  @override
  List<AudioPort> get inputs => [];
  @override
  List<AudioPort> get outputs => [output];

  @override
  SineOscillatorProcessor createProcessor() =>
      SineOscillatorProcessor(frequency: frequency);

  @override
  void updateProcessor(SineOscillatorProcessor processor) {
    processor.frequency = frequency;
  }
}

class SineOscillatorProcessor implements AudioProcessor {
  SineOscillatorProcessor({required this.frequency});

  /// In hertz.
  double frequency = 0.0;

  /// 0.0 - 1.0 normalized phase.
  double phase = 0.0;

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final output = outputs[0];
    final phaseIncrement = frequency / context.sampleRate;

    for (int i = 0; i < output.length; i++) {
      output[i] = math.sin(phase * (2 * math.pi));
      phase += phaseIncrement;
      if (phase >= 1.0) {
        phase -= 1.0;
      }
    }
  }
}
