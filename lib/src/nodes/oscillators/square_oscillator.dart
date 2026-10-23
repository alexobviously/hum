import 'dart:typed_data';

import 'package:hum/hum.dart';

import 'oscillator_utils.dart';

typedef SquareOscillatorParams = ({double? frequency, bool usePolyBlep});

class SquareOscillator extends OscillatorNode<SquareOscillatorProcessor> {
  @override
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

  @override
  Outlet get outlet => outlets.first;

  @override
  SquareOscillatorProcessor createProcessor() => SquareOscillatorProcessor(
    frequency: frequency.valueOrNull,
    usePolyBlep: usePolyBlep,
  );

  @override
  SquareOscillatorParams get params =>
      (frequency: frequency.valueOrNull, usePolyBlep: usePolyBlep);
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
  void update(Object params) {
    params = params as SquareOscillatorParams;
    frequency = params.frequency;
    usePolyBlep = params.usePolyBlep;
  }

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
