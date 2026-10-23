import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// The curvature shape used by [Adsr].
enum AdsrCurve {
  /// Pure linear ramps between stages.
  linear,

  /// Punchy exponential charge for attack and natural exponential discharge
  /// for decay and release, mimicking classic analog RC synthesizer circuits.
  exponential,
}

/// The operational state of the [Adsr] state machine.
enum AdsrState {
  idle,
  attack,
  decay,
  sustain,
  release,
}

typedef AdsrParams = ({
  double? attack,
  double? decay,
  double? sustain,
  double? release,
  AdsrCurve? curve,
});

/// Attack-Decay-Sustain-Release (ADSR) envelope generator.
///
/// Modulates volume, filter cutoff, or other parameters based on an audio-rate
/// [gate] signal. Sub-block sample-accurate gate edge detection ensures jitter-free
/// note articulation without quantization to block boundaries.
class Adsr({
  required final Outlet gate,
  final ControlParam<double> attack = const .value(0.01),
  final ControlParam<double> decay = const .value(0.1),
  final ControlParam<double> sustain = const .value(0.7),
  final ControlParam<double> release = const .value(0.3),
  final AdsrCurve curve = .exponential,
}) extends AudioNode<AdsrProcessor> {
  static const gateInlet = 0;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: gateInlet, source: gate),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;

  @override
  AdsrProcessor createProcessor() => AdsrProcessor(
    attack: attack.valueOrNull ?? 0.01,
    decay: decay.valueOrNull ?? 0.1,
    sustain: sustain.valueOrNull ?? 0.7,
    release: release.valueOrNull ?? 0.3,
    curve: curve,
  );

  @override
  AdsrParams get params => (
    attack: attack.valueOrNull,
    decay: decay.valueOrNull,
    sustain: sustain.valueOrNull,
    release: release.valueOrNull,
    curve: curve,
  );
}

class AdsrProcessor implements AudioProcessor {
  AdsrProcessor({
    required this.attack,
    required this.decay,
    required this.sustain,
    required this.release,
    this.curve = .exponential,
  });

  /// Attack time in seconds.
  double attack;

  /// Decay time in seconds.
  double decay;

  /// Sustain level (0.0 to 1.0).
  double sustain;

  /// Release time in seconds.
  double release;

  /// Envelope curve style.
  AdsrCurve curve;

  /// Current envelope output amplitude (0.0 to 1.0).
  double level = 0.0;

  /// Active state of the envelope.
  AdsrState state = AdsrState.idle;

  /// Gate state in the previous sample (for rising/falling edge detection).
  bool _lastGate = false;

  /// Linear rate accumulator for attack when retriggered mid-flight.
  double _linearAttackRate = 0.0;

  @override
  void update(Object params) {
    final p = params as AdsrParams;
    if (p.attack != null) attack = p.attack!;
    if (p.decay != null) decay = p.decay!;
    if (p.sustain != null) sustain = p.sustain!;
    if (p.release != null) release = p.release!;
    if (p.curve != null) curve = p.curve!;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final output = outputs[0];
    final gateBuffer = inputs[Adsr.gateInlet];
    final sampleRate = context.sampleRate.toDouble();

    // Cache parameters and coefficients for this block
    final double aTime = math.max(0.0001, attack);
    final double dTime = math.max(0.0001, decay);
    final double sLevel = sustain.clamp(0.0, 1.0);
    final double rTime = math.max(0.0001, release);
    final AdsrCurve activeCurve = curve;

    // Analog RC exponential coefficients:
    // Attack targets 1.5 (overshoot) to cross 1.0 in a finite time with punchy convex curvature.
    // ln(1.5 / (1.5 - 1.0)) = ln(3.0) ~= 1.098612
    final double expAttackCoeff =
        1.0 - math.exp(-1.098612 / (aTime * sampleRate));
    final double expDecayCoeff = 1.0 - math.exp(-3.0 / (dTime * sampleRate));
    // Release targets -0.01 (undershoot) to cleanly hit 0.0 in finite time.
    final double expReleaseCoeff = 1.0 - math.exp(-3.0 / (rTime * sampleRate));

    // Linear rates per sample
    final double linDecayRate = (1.0 - sLevel) / (dTime * sampleRate);
    final double linReleaseRate = 1.0 / (rTime * sampleRate);

    double currentLevel = level;
    AdsrState currentState = state;
    bool lastGate = _lastGate;
    double linAttackRate = _linearAttackRate;

    for (int i = 0; i < output.length; i++) {
      final bool gateHigh = gateBuffer[i] > 0.0;

      // Edge detection
      switch ((lastGate, gateHigh)) {
        case (false, true):
          // Gate Rising Edge: Trigger Note On / Attack
          currentState = .attack;
          if (activeCurve == .linear) {
            linAttackRate = (1.0 - currentLevel) / (aTime * sampleRate);
          }
        case (true, false) when currentState != .idle:
          // Gate Falling Edge: Trigger Note Off / Release
          currentState = .release;
        case _:
          break;
      }
      lastGate = gateHigh;

      // State machine evaluation
      switch (currentState) {
        case .idle:
          currentLevel = 0.0;

        case .attack:
          currentLevel += switch (activeCurve) {
            // Charge towards 1.5 overshoot
            .exponential => expAttackCoeff * (1.5 - currentLevel),
            .linear => linAttackRate,
          };

          if (currentLevel >= 1.0) {
            currentLevel = 1.0;
            currentState = .decay;
          }

        case .decay:
          currentLevel += switch (activeCurve) {
            .exponential => expDecayCoeff * (sLevel - currentLevel),
            .linear => -linDecayRate,
          };
          if (currentLevel <= sLevel ||
              (currentLevel - sLevel).abs() <= 0.0005) {
            currentLevel = sLevel;
            currentState = .sustain;
          }

        case .sustain:
          currentLevel = sLevel;

        case .release:
          currentLevel += switch (activeCurve) {
            // Discharge towards -0.01 undershoot
            .exponential => expReleaseCoeff * (-0.01 - currentLevel),
            .linear => -linReleaseRate,
          };
          if (currentLevel <= 0.0005) {
            currentLevel = 0.0;
            currentState = .idle;
          }
      }

      output[i] = currentLevel;
    }

    level = currentLevel;
    state = currentState;
    _lastGate = lastGate;
    _linearAttackRate = linAttackRate;
  }
}
