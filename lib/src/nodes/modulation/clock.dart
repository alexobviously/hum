import 'dart:typed_data';

import 'package:hum/hum.dart';

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
}) extends AudioNode<ClockProcessor> {
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

  static const gateOutlet = 0;
  static const triggerOutlet = 1;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: freqInlet, source: frequency.outletOrNull),
    Inlet(node: this, index: pulseWidthInlet, source: pulseWidth.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: gateOutlet),
    Outlet(node: this, index: triggerOutlet),
  ];

  /// Unipolar gate signal (1.0 for the duration of [pulseWidth], 0.0 otherwise).
  Outlet get gate => outlets[gateOutlet];

  /// A single-sample 1.0 impulse on the exact sample where each cycle begins.
  Outlet get trigger => outlets[triggerOutlet];

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [frequency, pulseWidth];

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

class ClockProcessor({
  /// In hertz. If null, driven by audio inlet.
  required var double? frequency,

  /// Duty cycle (0.0 to 1.0). If null, driven by audio inlet.
  var double? pulseWidth,
}) implements AudioProcessor {
  /// 0.0 to 1.0 normalised phase.
  double _phase = 0.0;

  /// Whether the next sample should emit a trigger impulse.
  bool _willTrigger = true;

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
    final gateOut = outputs[Clock.gateOutlet];
    final triggerOut = outputs[Clock.triggerOutlet];
    final sampleRate = context.sampleRate;
    double phase = _phase;
    bool willTrigger = _willTrigger;

    final bool hasSignalFreq = frequency == null && inputs.isNotEmpty;
    final bool hasSignalWidth =
        pulseWidth == null && inputs.length > Clock.pulseWidthInlet;

    final freqBuffer = hasSignalFreq ? inputs[Clock.freqInlet] : null;
    final widthBuffer = hasSignalWidth ? inputs[Clock.pulseWidthInlet] : null;

    final double staticFreq = frequency ?? 2.0;
    final double staticWidth = (pulseWidth ?? 0.5).clamp(0.0, 1.0);
    final double fallbackInc = staticFreq / sampleRate;

    if (!hasSignalFreq && !hasSignalWidth) {
      final double phaseIncrement = fallbackInc;

      for (int i = 0; i < gateOut.length; i++) {
        gateOut[i] = phase < staticWidth ? 1.0 : 0.0;
        triggerOut[i] = willTrigger ? 1.0 : 0.0;

        phase += phaseIncrement;
        // account for floating point precision drift
        if (phase >= 1.0 - 1e-9) {
          phase = (phase >= 1.0) ? phase - 1.0 : 0.0;
          willTrigger = true;
        } else {
          willTrigger = false;
        }
      }
    } else {
      for (int i = 0; i < gateOut.length; i++) {
        final double threshold = hasSignalWidth
            ? widthBuffer![i].clamp(0.0, 1.0)
            : staticWidth;
        final double inc = hasSignalFreq
            ? (freqBuffer![i] / sampleRate)
            : fallbackInc;

        gateOut[i] = phase < threshold ? 1.0 : 0.0;
        triggerOut[i] = willTrigger ? 1.0 : 0.0;

        phase += inc;
        // account for floating point precision drift
        if (phase >= 1.0 - 1e-9) {
          phase = (phase >= 1.0) ? phase - 1.0 : 0.0;
          willTrigger = true;
        } else {
          willTrigger = false;
        }
      }
    }

    _phase = phase;
    _willTrigger = willTrigger;
  }
}
