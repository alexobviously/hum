import 'dart:typed_data';

import 'package:dsp/dsp.dart';

import 'oscillator_utils.dart';

typedef TriangleOscillatorParams = ({double? frequency, bool usePolyBlep});

class TriangleOscillator
    implements OscillatorNode<TriangleOscillatorProcessor> {
  @override
  final ControlParam<double> frequency;
  final bool usePolyBlep;

  const TriangleOscillator({
    required this.frequency,
    this.usePolyBlep = true,
  });

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
  TriangleOscillatorProcessor createProcessor() => TriangleOscillatorProcessor(
    frequency: frequency.valueOrNull,
    usePolyBlep: usePolyBlep,
  );

  @override
  TriangleOscillatorParams get params =>
      (frequency: frequency.valueOrNull, usePolyBlep: usePolyBlep);
}

class TriangleOscillatorProcessor implements AudioProcessor {
  TriangleOscillatorProcessor({
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
    params = params as TriangleOscillatorParams;
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
          double sample = 4.0 * phase;
          if (sample >= 3.0) {
            sample -= 4.0;
          } else if (sample > 1.0) {
            sample = 2.0 - sample;
          }

          final t1 = phase < 0.75 ? phase + 0.25 : phase - 0.75;
          final t2 = phase < 0.25 ? phase + 0.75 : phase - 0.25;
          sample += 4.0 * dt * (polyBlamp(t1, dt) - polyBlamp(t2, dt));

          output[i] = sample;
          phase = advancePhase(phase, phaseIncrement);
        }
      } else {
        for (int i = 0; i < output.length; i++) {
          double sample = 4.0 * phase;
          if (sample >= 3.0) {
            sample -= 4.0;
          } else if (sample > 1.0) {
            sample = 2.0 - sample;
          }

          output[i] = sample;
          phase = advancePhase(phase, phaseIncrement);
        }
      }
    } else {
      final freqBuffer = inputs[TriangleOscillator.freqInlet];

      if (usePolyBlep) {
        for (int i = 0; i < output.length; i++) {
          final phaseIncrement = freqBuffer[i] / sampleRate;
          final dt = phaseIncrement.abs();

          double sample = 4.0 * phase;
          if (sample >= 3.0) {
            sample -= 4.0;
          } else if (sample > 1.0) {
            sample = 2.0 - sample;
          }

          final t1 = phase < 0.75 ? phase + 0.25 : phase - 0.75;
          final t2 = phase < 0.25 ? phase + 0.75 : phase - 0.25;
          sample += 4.0 * dt * (polyBlamp(t1, dt) - polyBlamp(t2, dt));

          output[i] = sample;
          phase = advancePhase(phase, phaseIncrement);
        }
      } else {
        for (int i = 0; i < output.length; i++) {
          final phaseIncrement = freqBuffer[i] / sampleRate;

          double sample = 4.0 * phase;
          if (sample >= 3.0) {
            sample -= 4.0;
          } else if (sample > 1.0) {
            sample = 2.0 - sample;
          }

          output[i] = sample;
          phase = advancePhase(phase, phaseIncrement);
        }
      }
    }

    this.phase = phase;
  }
}
