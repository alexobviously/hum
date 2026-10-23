import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

// TODO: fully check this code, it's LLM generated

/// The curvature shape used by [Decay].
enum DecayCurve {
  /// Pure linear ramp down to 0.0.
  linear,

  /// Natural exponential discharge mimicking analog RC envelope circuits.
  exponential,
}

/// The operational state of the [Decay] state machine.
enum DecayState {
  idle,
  attack,
  decay,
}

typedef DecayParams = ({
  double? decay,
  double? attack,
  DecayCurve? curve,
});

/// Type aliases for [Decay].
typedef Ar = Decay;
typedef DecayEnvelope = Decay;

/// A one-shot, trigger-driven Decay and Attack-Decay (AR) envelope generator.
///
/// Designed specifically for percussion (kick pitch sweeps, snare bodies, hi-hats),
/// plucks, and modular modulation transients.
///
/// Unlike [Adsr], which is gate-driven and holds sustain as long as gate is high,
/// [Decay] responds strictly to rising edges on its [trigger] inlet. Once triggered,
/// it fires and completes its decay down to 0.0 regardless of how long the input
/// signal stays high.
///
/// When [attack] is 0.0 (the default), the envelope attacks instantaneously (outputting
/// 1.0 on the very sample the trigger arrives) and immediately begins its exponential
/// decay, providing maximum punch for transients.
///
/// When [attack] is greater than 0.0, the envelope rises smoothly from its current
/// amplitude to 1.0 over [attack] seconds before entering decay, avoiding clicks
/// during mid-flight retriggering.
class Decay({
  required final Outlet trigger,
  final ControlParam<double> decay = const .value(0.1),
  final ControlParam<double> attack = const .value(0.0),
  final DecayCurve curve = .exponential,
}) extends AudioNode<DecayProcessor> {
  static const triggerInlet = 0;

  /// Creates a pure one-shot decay envelope with instant (0s) attack.
  factory pure({
    required Outlet trigger,
    ControlParam<double> time = const .value(0.1),
    DecayCurve curve = .exponential,
  }) => Decay(
    trigger: trigger,
    decay: time,
    attack: const .value(0.0),
    curve: curve,
  );

  /// Creates an Attack-Decay (AR) envelope with configurable attack and decay times.
  factory ar({
    required Outlet trigger,
    ControlParam<double> attack = const .value(0.01),
    ControlParam<double> decay = const .value(0.1),
    DecayCurve curve = .exponential,
  }) => Decay(
    trigger: trigger,
    attack: attack,
    decay: decay,
    curve: curve,
  );

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: triggerInlet, source: trigger),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;

  @override
  DecayProcessor createProcessor() => DecayProcessor(
    decay: decay.valueOrNull ?? 0.1,
    attack: attack.valueOrNull ?? 0.0,
    curve: curve,
  );

  @override
  DecayParams get params => (
    decay: decay.valueOrNull,
    attack: attack.valueOrNull,
    curve: curve,
  );
}

class DecayProcessor implements AudioProcessor {
  DecayProcessor({
    required this.decay,
    this.attack = 0.0,
    this.curve = .exponential,
  });

  /// Decay time in seconds.
  double decay;

  /// Attack time in seconds (0.0 for instant 1-sample rise).
  double attack;

  /// Envelope curve style.
  DecayCurve curve;

  /// Current envelope output amplitude (0.0 to 1.0).
  double level = 0.0;

  /// Active state of the envelope.
  DecayState state = DecayState.idle;

  /// Trigger state in previous sample (for rising edge detection).
  bool _lastTrigger = false;

  /// Linear rate accumulator for attack when retriggered mid-flight.
  double _linearAttackRate = 0.0;

  @override
  void update(Object params) {
    final p = params as DecayParams;
    if (p.decay != null) decay = p.decay!;
    if (p.attack != null) attack = p.attack!;
    if (p.curve != null) curve = p.curve!;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final output = outputs[0];
    final triggerBuffer = inputs[Decay.triggerInlet];
    final sampleRate = context.sampleRate.toDouble();

    final double dTime = math.max(0.0001, decay);
    final double aTime = math.max(0.0001, attack);
    final bool hasAttack = attack > 0.0;
    final DecayCurve activeCurve = curve;

    // Analog RC exponential coefficients:
    // Attack targets 1.5 overshoot to cross 1.0 in finite time: ln(3) ~= 1.098612
    final double expAttackCoeff =
        1.0 - math.exp(-1.098612 / (aTime * sampleRate));
    // Decay targets -0.01 undershoot to cleanly hit 0.0 in finite time:
    final double expDecayCoeff = 1.0 - math.exp(-3.0 / (dTime * sampleRate));

    // Linear rates per sample:
    final double linDecayRate = 1.0 / (dTime * sampleRate);

    double currentLevel = level;
    DecayState currentState = state;
    bool lastTrigger = _lastTrigger;
    double linAttackRate = _linearAttackRate;

    for (int i = 0; i < output.length; i++) {
      final bool triggerHigh = triggerBuffer[i] > 0.0;
      final bool isRisingEdge = !lastTrigger && triggerHigh;
      lastTrigger = triggerHigh;

      if (isRisingEdge) {
        if (!hasAttack) {
          currentLevel = 1.0;
          currentState = .decay;
          output[i] = 1.0;
          continue;
        } else {
          currentState = .attack;
          if (activeCurve == .linear) {
            linAttackRate = (1.0 - currentLevel) / (aTime * sampleRate);
          }
        }
      }

      switch (currentState) {
        case .idle:
          currentLevel = 0.0;

        case .attack:
          currentLevel += switch (activeCurve) {
            .exponential => expAttackCoeff * (1.5 - currentLevel),
            .linear => linAttackRate,
          };
          if (currentLevel >= 1.0) {
            currentLevel = 1.0;
            currentState = .decay;
          }

        case .decay:
          currentLevel += switch (activeCurve) {
            .exponential => expDecayCoeff * (-0.01 - currentLevel),
            .linear => -linDecayRate,
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
    _lastTrigger = lastTrigger;
    _linearAttackRate = linAttackRate;
  }
}

extension OutletDecayExtension on Outlet {
  /// Applies a trigger-fired decay envelope to this trigger outlet.
  Decay decay([
    double time = 0.1,
    double attack = 0.0,
    DecayCurve curve = DecayCurve.exponential,
  ]) => Decay(
    trigger: this,
    decay: .value(time),
    attack: .value(attack),
    curve: curve,
  );
}
