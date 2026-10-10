import 'dart:typed_data';

import 'package:dsp/dsp.dart';

import 'oscillator_utils.dart';

typedef SawtoothOscillatorParams = ({double? frequency, bool usePolyBlep});

class SawtoothOscillator implements AudioNode<SawtoothOscillatorProcessor> {
  final ControlParam<double> frequency;
  final bool usePolyBlep;

  const SawtoothOscillator({required this.frequency, this.usePolyBlep = true});

  static const freqInlet = 0;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: freqInlet, source: frequency.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;

  @override
  SawtoothOscillatorProcessor createProcessor() => SawtoothOscillatorProcessor(
    frequency: frequency.valueOrNull,
    usePolyBlep: usePolyBlep,
  );

  @override
  SawtoothOscillatorParams get params =>
      (frequency: frequency.valueOrNull, usePolyBlep: usePolyBlep);
}

class SawtoothOscillatorProcessor implements AudioProcessor {
  SawtoothOscillatorProcessor({
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
    params = params as SawtoothOscillatorParams;
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
      final dt = phaseIncrement.abs();

      for (int i = 0; i < output.length; i++) {
        double sample = 2.0 * phase - 1.0;

        if (usePolyBlep) {
          sample -= polyBlep(phase, dt);
        }

        output[i] = sample;
        phase = advancePhase(phase, phaseIncrement);
      }
    } else {
      final freqBuffer = inputs[SawtoothOscillator.freqInlet];

      for (int i = 0; i < output.length; i++) {
        final phaseIncrement = freqBuffer[i] / sampleRate;
        double sample = 2.0 * phase - 1.0;
        if (usePolyBlep) {
          sample -= polyBlep(phase, phaseIncrement.abs());
        }
        output[i] = sample;
        phase = advancePhase(phase, phaseIncrement);
      }
    }

    this.phase = phase;
  }
}
