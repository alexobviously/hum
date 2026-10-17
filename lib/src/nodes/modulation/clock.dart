import 'dart:typed_data';

import 'package:dsp/dsp.dart';
import 'package:dsp/src/nodes/oscillators/oscillator_utils.dart';

typedef ClockParams = ({double? frequency, double? pulseWidth});

/// An unipolar (0.0 or 1.0) pulse oscillator designed for rhythmic clocking,
/// metronome pulses, and gate generation.
///
/// Unlike [SquareOscillator], [Clock] produces non-bandlimited sharp digital
/// edges (no PolyBLEP smoothing) to ensure zero-crossing edge detectors and
/// [Adsr] trigger on exact single samples.
class Clock({
  final ControlParam<double> frequency = const .value(2.0),
  final ControlParam<double> pulseWidth = const .value(0.5),
}) implements AudioNode<ClockProcessor> {
  /// Convenience factory configuring clock frequency from musical beats-per-minute (BPM).
  ///
  /// For example, 120 BPM corresponds to 2.0 Hz.
  factory bpm(
    double bpm, {
    ControlParam<double> pulseWidth = const .value(0.5),
  }) => Clock(
    frequency: .value(bpm / 60.0),
    pulseWidth: pulseWidth,
  );

  static const freqInlet = 0;
  static const pulseWidthInlet = 1;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: freqInlet, source: frequency.outletOrNull),
    Inlet(node: this, index: pulseWidthInlet, source: pulseWidth.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;

  @override
  ClockProcessor createProcessor() => ClockProcessor(
    frequency: frequency.valueOrNull,
    pulseWidth: pulseWidth.valueOrNull,
  );

  @override
  ClockParams get params => (
    frequency: frequency.valueOrNull,
    pulseWidth: pulseWidth.valueOrNull,
  );
}

class ClockProcessor implements AudioProcessor {
  ClockProcessor({
    required this.frequency,
    this.pulseWidth,
  });

  /// In hertz. If null, driven by audio inlet.
  double? frequency;

  /// Duty cycle (0.0 to 1.0). If null, driven by audio inlet.
  double? pulseWidth;

  /// 0.0 to 1.0 normalised phase.
  double phase = 0.0;

  @override
  void update(Object params) {
    final p = params as ClockParams;
    frequency = p.frequency;
    pulseWidth = p.pulseWidth;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final output = outputs[0];
    final sampleRate = context.sampleRate;
    double currentPhase = phase;

    final bool hasSignalFreq = frequency == null && inputs.isNotEmpty;
    final bool hasSignalWidth =
        pulseWidth == null && inputs.length > Clock.pulseWidthInlet;

    final freqBuffer = hasSignalFreq ? inputs[Clock.freqInlet] : null;
    final widthBuffer = hasSignalWidth ? inputs[Clock.pulseWidthInlet] : null;

    final double staticFreq = frequency ?? 2.0;
    final double staticWidth = (pulseWidth ?? 0.5).clamp(0.0, 1.0);

    if (!hasSignalFreq && !hasSignalWidth) {
      // Scalar fast path: fixed frequency and fixed pulse width
      final double phaseIncrement = staticFreq / sampleRate;

      for (int i = 0; i < output.length; i++) {
        output[i] = currentPhase < staticWidth ? 1.0 : 0.0;
        currentPhase = advancePhase(currentPhase, phaseIncrement);
      }
    } else {
      // Modulated path: frequency or pulse width driven by audio-rate signals
      final double fallbackInc = staticFreq / sampleRate;

      for (int i = 0; i < output.length; i++) {
        final double threshold = hasSignalWidth
            ? widthBuffer![i].clamp(0.0, 1.0)
            : staticWidth;
        output[i] = currentPhase < threshold ? 1.0 : 0.0;

        final double phaseIncrement = hasSignalFreq
            ? (freqBuffer![i] / sampleRate)
            : fallbackInc;
        currentPhase = advancePhase(currentPhase, phaseIncrement);
      }
    }

    phase = currentPhase;
  }
}
