import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

// TODO: fully check this code, it's LLM generated

/// The operational state of the [Decay] state machine.
enum DecayState {
  idle,
  attack,
  decay,
}

typedef DecayParams = ({
  double? decay,
  double? attack,
  EnvelopeCurve? curve,
});

/// Type alias for [Decay].
typedef DecayEnvelope = Decay;

/// A one-shot, trigger-driven Decay and Attack-Decay envelope generator.
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
  final EnvelopeCurve curve = .exponential,
}) extends AudioNode<DecayProcessor> {
  static const triggerInlet = 0;
  static const decayInlet = 1;
  static const attackInlet = 2;

  /// Creates a pure one-shot decay envelope with instant (0s) attack.
  factory pure({
    required Outlet trigger,
    ControlParam<double> time = const .value(0.1),
    EnvelopeCurve curve = .exponential,
  }) => Decay(
    trigger: trigger,
    decay: time,
    attack: const .value(0.0),
    curve: curve,
  );

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: triggerInlet, source: trigger),
    Inlet(node: this, index: decayInlet, source: decay.outletOrNull),
    Inlet(node: this, index: attackInlet, source: attack.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [decay, attack, curve];

  @override
  DecayProcessor createProcessor() => DecayProcessor(
    decay: decay.valueOrNull,
    attack: attack.valueOrNull,
    curve: curve,
  );

  @override
  DecayParams get params => (
    decay: decay.valueOrNull,
    attack: attack.valueOrNull,
    curve: curve,
  );
}

class DecayProcessor({
  /// Decay time in seconds. If null, driven by [Decay.decayInlet].
  var double? decay = 0.1,

  /// Attack time in seconds (0.0 for instant 1-sample rise). If null, driven by [Decay.attackInlet].
  var double? attack = 0.0,

  /// Envelope curve style.
  var EnvelopeCurve curve = .exponential,
}) implements AudioProcessor {
  // ln(1.5 / (1.5 - 1.0)) = ln(3.0): crosses 1.0 at t = attack with 0.5 overshoot.
  static const double _expAttackLog = 1.0986122886681098;
  // ln(1.05 / 0.05) = ln(21.0): crosses 0.0 at t = decay with 5% undershoot.
  static const double _expDecayLog = 3.044522437723423;
  static const double _expUndershoot = 0.05;
  /// Current envelope output amplitude (0.0 to 1.0).
  double level = 0.0;

  /// Active state of the envelope.
  DecayState state = .idle;

  /// Trigger state in previous sample (for rising edge detection).
  bool _lastTrigger = false;

  /// Linear rate accumulator for attack when retriggered mid-flight.
  double _linearAttackRate = 0.0;

  double _cachedDecay = -1.0;
  double _cachedAttack = -1.0;
  double _cachedSampleRate = 0.0;
  double _aTime = 0.0001;
  double _expAttackCoeff = 0.0;
  double _expDecayCoeff = 0.0;
  double _linDecayRate = 0.0;

  @override
  void update(Object params) {
    final p = params as DecayParams;
    decay = p.decay;
    attack = p.attack;
    if (p.curve != null) curve = p.curve!;
  }

  @pragma('vm:prefer-inline')
  void _updateAttackCache(double rawAttack, double sampleRate) {
    _cachedAttack = rawAttack;
    _aTime = rawAttack > 0.0001 ? rawAttack : 0.0001;
    _expAttackCoeff = 1.0 - math.exp(-_expAttackLog / (_aTime * sampleRate));
  }

  @pragma('vm:prefer-inline')
  void _updateDecayCache(double rawDecay, double sampleRate) {
    _cachedDecay = rawDecay;
    final double dTime = rawDecay > 0.0001 ? rawDecay : 0.0001;
    _expDecayCoeff = 1.0 - math.exp(-_expDecayLog / (dTime * sampleRate));
    _linDecayRate = 1.0 / (dTime * sampleRate);
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

    if (sampleRate != _cachedSampleRate) {
      _cachedSampleRate = sampleRate;
      _cachedDecay = -1.0;
      _cachedAttack = -1.0;
    }

    final bool hasDecaySignal =
        decay == null && inputs.length > Decay.decayInlet;
    final bool hasAttackSignal =
        attack == null && inputs.length > Decay.attackInlet;

    final double staticDecay = decay ?? 0.1;
    final double staticAttack = attack ?? 0.0;
    final EnvelopeCurve activeCurve = curve;

    if (!hasDecaySignal && staticDecay != _cachedDecay) {
      _updateDecayCache(staticDecay, sampleRate);
    }
    if (!hasAttackSignal && staticAttack != _cachedAttack) {
      _updateAttackCache(staticAttack, sampleRate);
    }

    double currentLevel = level;
    DecayState currentState = state;
    bool lastTrigger = _lastTrigger;
    double linAttackRate = _linearAttackRate;

    if (!hasDecaySignal && !hasAttackSignal) {
      final bool hasAttack = staticAttack > 0.0;
      final double expAttackCoeff = _expAttackCoeff;
      final double expDecayCoeff = _expDecayCoeff;
      final double linDecayRate = _linDecayRate;
      final double aTime = _aTime;

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
            // Computed regardless of curve because it could switch mid-attack.
            linAttackRate = (1.0 - currentLevel) / (aTime * sampleRate);
          }
        }

        switch (currentState) {
          case .idle:
            currentLevel = 0.0;

          case .attack:
            switch (activeCurve) {
              case .exponential:
                currentLevel += expAttackCoeff * (1.5 - currentLevel);
              case .linear:
                currentLevel += linAttackRate;
            }
            if (currentLevel >= 1.0) {
              currentLevel = 1.0;
              currentState = .decay;
            }

          case .decay:
            switch (activeCurve) {
              case .exponential:
                currentLevel += expDecayCoeff * (-_expUndershoot - currentLevel);
              case .linear:
                currentLevel -= linDecayRate;
            }
            if (currentLevel <= 0.0) {
              currentLevel = 0.0;
              currentState = .idle;
            }
        }

        output[i] = currentLevel;
      }
    } else {
      final decayBuffer = hasDecaySignal ? inputs[Decay.decayInlet] : null;
      final attackBuffer = hasAttackSignal ? inputs[Decay.attackInlet] : null;

      for (int i = 0; i < output.length; i++) {
        final bool triggerHigh = triggerBuffer[i] > 0.0;
        final bool isRisingEdge = !lastTrigger && triggerHigh;
        lastTrigger = triggerHigh;

        if (isRisingEdge) {
          final double rawA = attackBuffer != null
              ? attackBuffer[i]
              : staticAttack;
          if (rawA <= 0.0) {
            currentLevel = 1.0;
            currentState = .decay;
            output[i] = 1.0;
            continue;
          } else {
            currentState = .attack;
            final double aTime = rawA > 0.0001 ? rawA : 0.0001;
            linAttackRate = (1.0 - currentLevel) / (aTime * sampleRate);
          }
        }

        switch (currentState) {
          case .idle:
            currentLevel = 0.0;

          case .attack:
            switch (activeCurve) {
              case .exponential:
                if (attackBuffer != null) {
                  final double rawA = attackBuffer[i];
                  if (rawA != _cachedAttack) {
                    _updateAttackCache(rawA, sampleRate);
                  }
                }
                currentLevel += _expAttackCoeff * (1.5 - currentLevel);
              case .linear:
                currentLevel += linAttackRate;
            }
            if (currentLevel >= 1.0) {
              currentLevel = 1.0;
              currentState = .decay;
            }

          case .decay:
            if (decayBuffer != null) {
              final double rawD = decayBuffer[i];
              if (rawD != _cachedDecay) {
                _updateDecayCache(rawD, sampleRate);
              }
            }
            switch (activeCurve) {
              case .exponential:
                currentLevel += _expDecayCoeff * (-_expUndershoot - currentLevel);
              case .linear:
                currentLevel -= _linDecayRate;
            }
            if (currentLevel <= 0.0) {
              currentLevel = 0.0;
              currentState = .idle;
            }
        }

        output[i] = currentLevel;
      }
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
    EnvelopeCurve curve = EnvelopeCurve.exponential,
  ]) => Decay(
    trigger: this,
    decay: .value(time),
    attack: .value(attack),
    curve: curve,
  );
}
