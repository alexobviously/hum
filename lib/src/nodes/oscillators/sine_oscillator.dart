import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsp/dsp.dart';

class SineOscillator implements AudioNode<SineOscillatorProcessor> {
  final ControlParam<double> frequency;
  const SineOscillator({required this.frequency});

  AudioPort get output => AudioPort(node: this, index: 0);

  @override
  List<AudioPort> get inputs => [
    if (frequency case ControlParamSignal(:final port)) port,
  ];

  @override
  List<AudioPort> get outputs => [output];

  @override
  SineOscillatorProcessor createProcessor() => SineOscillatorProcessor(
    frequency: switch (frequency) {
      ControlParamValue(:final value) => value,
      ControlParamSignal() => null,
    },
  );

  @override
  void updateProcessor(SineOscillatorProcessor processor) {
    processor.frequency = switch (frequency) {
      ControlParamValue(:final value) => value,
      ControlParamSignal() => null,
    };
  }
}

class SineOscillatorProcessor implements AudioProcessor {
  SineOscillatorProcessor({required this.frequency});

  /// In hertz.
  double? frequency;

  /// 0.0 - 1.0 normalized phase.
  double phase = 0.0;

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final output = outputs[0];
    final frequency = this.frequency;

    if (frequency != null) {
      final phaseIncrement = frequency / context.sampleRate;

      for (int i = 0; i < output.length; i++) {
        output[i] = math.sin(phase * 2 * math.pi);

        phase += phaseIncrement;
        if (phase >= 1.0) phase -= 1.0;
      }
    } else {
      final freqBuffer = inputs[0];

      for (int i = 0; i < context.vectorSize; i++) {
        output[i] = math.sin(phase * 2 * math.pi);

        phase += freqBuffer[i] / context.sampleRate;
        if (phase >= 1.0) phase -= 1.0;
      }
    }
  }
}
