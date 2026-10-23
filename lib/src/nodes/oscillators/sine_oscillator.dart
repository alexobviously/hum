import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef SineOscillatorParams = ({double? frequency});

class SineOscillator extends OscillatorNode<SineOscillatorProcessor> {
  @override
  final ControlParam<double> frequency;
  const SineOscillator({required this.frequency});

  static const freqInlet = 0;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: freqInlet, source: frequency.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  @override
  Outlet get outlet => outlets.first;

  @override
  SineOscillatorProcessor createProcessor() => SineOscillatorProcessor(
    frequency: frequency.valueOrNull,
  );

  @override
  SineOscillatorParams get params => (frequency: frequency.valueOrNull);
}

class SineOscillatorProcessor implements AudioProcessor {
  SineOscillatorProcessor({required this.frequency});

  /// In hertz.
  double? frequency;

  /// 0.0 - 1.0 normalized phase.
  double phase = 0.0;

  @override
  void update(Object params) {
    params = params as SineOscillatorParams;
    frequency = params.frequency;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final output = outputs[0];
    final frequency = this.frequency;

    if (frequency != null) {
      // Constant branch
      final phaseIncrement = frequency / context.sampleRate;

      for (int i = 0; i < output.length; i++) {
        output[i] = math.sin(phase * 2 * math.pi);

        phase += phaseIncrement;
        if (phase >= 1.0) phase -= 1.0;
      }
    } else {
      // Signal branch
      final freqBuffer = inputs[SineOscillator.freqInlet];

      for (int i = 0; i < context.vectorSize; i++) {
        output[i] = math.sin(phase * 2 * math.pi);

        phase += freqBuffer[i] / context.sampleRate;
        if (phase >= 1.0) phase -= 1.0;
      }
    }
  }
}
