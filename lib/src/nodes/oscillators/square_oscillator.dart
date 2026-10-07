import 'dart:typed_data';

import 'package:dsp/dsp.dart';

import 'oscillator_utils.dart';

class SquareOscillator implements AudioNode<SquareOscillatorProcessor> {
  final ControlParam<double> frequency;
  final bool usePolyBlep;

  const SquareOscillator({required this.frequency, this.usePolyBlep = true});

  static const freqInlet = 0;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: freqInlet, source: frequency.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;

  @override
  SquareOscillatorProcessor createProcessor() => SquareOscillatorProcessor(
    frequency: frequency.valueOrNull,
    usePolyBlep: usePolyBlep,
  );

  @override
  void updateProcessor(SquareOscillatorProcessor processor) {
    processor.frequency = frequency.valueOrNull;
    processor.usePolyBlep = usePolyBlep;
  }
}

class SquareOscillatorProcessor implements AudioProcessor {
  SquareOscillatorProcessor({
    required this.frequency,
    this.usePolyBlep = true,
  });

  /// In hertz.
  double? frequency;

  /// For antialiasing.
  bool usePolyBlep;

  /// 0.0 - 1.0 normalised phase.
  double phase = 0.0;

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final output = outputs[0];
    final frequency = this.frequency;
    final sampleRate = context.sampleRate;
    double phase = this.phase;
    final usePolyBlep = this.usePolyBlep;

    if (frequency != null) {
      final phaseIncrement = frequency / sampleRate;

      if (usePolyBlep) {
        final dt = phaseIncrement.abs();
        for (int i = 0; i < output.length; i++) {
          double sample = phase < 0.5 ? 1.0 : -1.0;
          final secondEdgePhase = phase < 0.5 ? phase + 0.5 : phase - 0.5;
          sample += polyBlep(phase, dt);
          sample -= polyBlep(secondEdgePhase, dt);
          output[i] = sample;
          phase = advancePhase(phase, phaseIncrement);
        }
      } else {
        for (int i = 0; i < output.length; i++) {
          output[i] = phase < 0.5 ? 1.0 : -1.0;
          phase = advancePhase(phase, phaseIncrement);
        }
      }
    } else {
      final freqBuffer = inputs[SquareOscillator.freqInlet];

      if (usePolyBlep) {
        for (int i = 0; i < output.length; i++) {
          final phaseIncrement = freqBuffer[i] / sampleRate;
          final dt = phaseIncrement.abs();
          double sample = phase < 0.5 ? 1.0 : -1.0;
          final secondEdgePhase = phase < 0.5 ? phase + 0.5 : phase - 0.5;
          sample += polyBlep(phase, dt);
          sample -= polyBlep(secondEdgePhase, dt);
          output[i] = sample;
          phase = advancePhase(phase, phaseIncrement);
        }
      } else {
        for (int i = 0; i < output.length; i++) {
          final phaseIncrement = freqBuffer[i] / sampleRate;
          output[i] = phase < 0.5 ? 1.0 : -1.0;
          phase = advancePhase(phase, phaseIncrement);
        }
      }
    }

    this.phase = phase;
  }
}
