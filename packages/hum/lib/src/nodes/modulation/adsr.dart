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
  static const attackInlet = 1;
  static const decayInlet = 2;
  static const sustainInlet = 3;
  static const releaseInlet = 4;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: gateInlet, source: gate),
    Inlet(node: this, index: attackInlet, source: attack.outletOrNull),
    Inlet(node: this, index: decayInlet, source: decay.outletOrNull),
    Inlet(node: this, index: sustainInlet, source: sustain.outletOrNull),
    Inlet(node: this, index: releaseInlet, source: release.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [attack, decay, sustain, release, curve];

  @override
  AdsrProcessor createProcessor() => AdsrProcessor(
    attack: attack.valueOrNull,
    decay: decay.valueOrNull,
    sustain: sustain.valueOrNull,
    release: release.valueOrNull,
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
    this.attack = 0.01,
    this.decay = 0.1,
    this.sustain = 0.7,
    this.release = 0.3,
    this.curve = .exponential,
  });

  /// Attack time in seconds. If null, driven by [Adsr.attackInlet].
  double? attack;

  /// Decay time in seconds. If null, driven by [Adsr.decayInlet].
  double? decay;

  /// Sustain level (0.0 to 1.0). If null, driven by [Adsr.sustainInlet].
  double? sustain;

  /// Release time in seconds. If null, driven by [Adsr.releaseInlet].
  double? release;

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

  // Cached coefficients for zero-allocation steady-state processing
  double _cachedAttack = -1.0;
  double _cachedDecay = -1.0;
  double _cachedSustain = -1.0;
  double _cachedRelease = -1.0;
  double _cachedSampleRate = -1.0;

  double _aTime = 0.01;
  double _dTime = 0.1;
  double _sLevel = 0.7;
  double _expAttackCoeff = 0.0;
  double _expDecayCoeff = 0.0;
  double _expReleaseCoeff = 0.0;
  double _linDecayRate = 0.0;
  double _linReleaseRate = 0.0;

  @override
  void update(Object params) {
    final p = params as AdsrParams;
    attack = p.attack;
    decay = p.decay;
    sustain = p.sustain;
    release = p.release;
    if (p.curve != null) curve = p.curve!;
  }

  @pragma('vm:prefer-inline')
  void _updateAttackCache(double rawAttack, double sampleRate) {
    _cachedAttack = rawAttack;
    _aTime = rawAttack > 0.0001 ? rawAttack : 0.0001;
    // Analog RC exponential coefficient:
    // Attack targets 1.5 (overshoot) to cross 1.0 in a finite time with punchy convex curvature.
    // ln(1.5 / (1.5 - 1.0)) = ln(3.0) ~= 1.098612
    _expAttackCoeff = 1.0 - math.exp(-1.098612 / (_aTime * sampleRate));
  }

  @pragma('vm:prefer-inline')
  void _updateDecayCache(double rawDecay, double sLevel, double sampleRate) {
    _cachedDecay = rawDecay;
    _dTime = rawDecay > 0.0001 ? rawDecay : 0.0001;
    _expDecayCoeff = 1.0 - math.exp(-3.0 / (_dTime * sampleRate));
    _linDecayRate = (1.0 - sLevel) / (_dTime * sampleRate);
  }

  @pragma('vm:prefer-inline')
  void _updateReleaseCache(double rawRelease, double sampleRate) {
    _cachedRelease = rawRelease;
    final double rTime = rawRelease > 0.0001 ? rawRelease : 0.0001;
    // Release targets -0.01 (undershoot) to cleanly hit 0.0 in finite time.
    _expReleaseCoeff = 1.0 - math.exp(-3.0 / (rTime * sampleRate));
    _linReleaseRate = 1.0 / (rTime * sampleRate);
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

    if (sampleRate != _cachedSampleRate) {
      _cachedSampleRate = sampleRate;
      _cachedAttack = -1.0;
      _cachedDecay = -1.0;
      _cachedSustain = -1.0;
      _cachedRelease = -1.0;
    }

    final bool hasAttackSignal =
        attack == null && inputs.length > Adsr.attackInlet;
    final bool hasDecaySignal =
        decay == null && inputs.length > Adsr.decayInlet;
    final bool hasSustainSignal =
        sustain == null && inputs.length > Adsr.sustainInlet;
    final bool hasReleaseSignal =
        release == null && inputs.length > Adsr.releaseInlet;

    final double staticAttack = attack ?? 0.01;
    final double staticDecay = decay ?? 0.1;
    final double staticSustain = sustain ?? 0.7;
    final double staticRelease = release ?? 0.3;

    if (!hasSustainSignal && staticSustain != _cachedSustain) {
      _cachedSustain = staticSustain;
      _sLevel = staticSustain.fastClamp(0.0, 1.0);
      _cachedDecay = -1.0; // Recompute _linDecayRate for new sustain level
    }
    if (!hasAttackSignal && staticAttack != _cachedAttack) {
      _updateAttackCache(staticAttack, sampleRate);
    }
    if (!hasDecaySignal && staticDecay != _cachedDecay) {
      _updateDecayCache(staticDecay, _sLevel, sampleRate);
    }
    if (!hasReleaseSignal && staticRelease != _cachedRelease) {
      _updateReleaseCache(staticRelease, sampleRate);
    }

    double currentLevel = level;
    AdsrState currentState = state;
    bool lastGate = _lastGate;
    double linAttackRate = _linearAttackRate;

    final bool isExp = curve == AdsrCurve.exponential;

    if (!hasAttackSignal &&
        !hasDecaySignal &&
        !hasSustainSignal &&
        !hasReleaseSignal) {
      final double sLevel = _sLevel;
      final double aTime = _aTime;
      final double expAttackCoeff = _expAttackCoeff;
      final double expDecayCoeff = _expDecayCoeff;
      final double expReleaseCoeff = _expReleaseCoeff;
      final double linDecayRate = _linDecayRate;
      final double linReleaseRate = _linReleaseRate;

      for (int i = 0; i < output.length; i++) {
        final bool gateHigh = gateBuffer[i] > 0.0;

        // Edge detection
        if (!lastGate && gateHigh) {
          // Gate Rising Edge: Trigger Note On / Attack
          currentState = .attack;
          if (!isExp) {
            linAttackRate = (1.0 - currentLevel) / (aTime * sampleRate);
          }
        } else if (lastGate && !gateHigh && currentState != .idle) {
          // Gate Falling Edge: Trigger Note Off / Release
          currentState = .release;
        }
        lastGate = gateHigh;

        // State machine evaluation
        switch (currentState) {
          case .idle:
            currentLevel = 0.0;

          case .attack:
            currentLevel += isExp
                ? expAttackCoeff * (1.5 - currentLevel)
                : linAttackRate;

            if (currentLevel >= 1.0) {
              currentLevel = 1.0;
              currentState = .decay;
            }

          case .decay:
            currentLevel += isExp
                ? expDecayCoeff * (sLevel - currentLevel)
                : -linDecayRate;
            if (currentLevel <= sLevel || currentLevel - sLevel <= 0.0005) {
              currentLevel = sLevel;
              currentState = .sustain;
            }

          case .sustain:
            currentLevel = sLevel;

          case .release:
            currentLevel += isExp
                ? expReleaseCoeff * (-0.01 - currentLevel)
                : -linReleaseRate;
            if (currentLevel <= 0.0005) {
              currentLevel = 0.0;
              currentState = .idle;
            }
        }

        output[i] = currentLevel;
      }
    } else {
      final attackBuffer = hasAttackSignal ? inputs[Adsr.attackInlet] : null;
      final decayBuffer = hasDecaySignal ? inputs[Adsr.decayInlet] : null;
      final sustainBuffer = hasSustainSignal ? inputs[Adsr.sustainInlet] : null;
      final releaseBuffer = hasReleaseSignal ? inputs[Adsr.releaseInlet] : null;

      for (int i = 0; i < output.length; i++) {
        final bool gateHigh = gateBuffer[i] > 0.0;

        // Edge detection
        if (!lastGate && gateHigh) {
          currentState = .attack;
          if (!isExp) {
            final double rawA = attackBuffer != null
                ? attackBuffer[i]
                : staticAttack;
            final double aTime = rawA > 0.0001 ? rawA : 0.0001;
            linAttackRate = (1.0 - currentLevel) / (aTime * sampleRate);
          }
        } else if (lastGate && !gateHigh && currentState != .idle) {
          currentState = .release;
        }
        lastGate = gateHigh;

        // State machine evaluation
        switch (currentState) {
          case .idle:
            currentLevel = 0.0;

          case .attack:
            if (isExp) {
              if (attackBuffer != null) {
                final double rawA = attackBuffer[i];
                if (rawA != _cachedAttack) {
                  _updateAttackCache(rawA, sampleRate);
                }
              }
              currentLevel += _expAttackCoeff * (1.5 - currentLevel);
            } else {
              currentLevel += linAttackRate;
            }

            if (currentLevel >= 1.0) {
              currentLevel = 1.0;
              currentState = .decay;
            }

          case .decay:
            final double sLevel = sustainBuffer != null
                ? sustainBuffer[i].fastClamp(0.0, 1.0)
                : _sLevel;
            if (decayBuffer != null) {
              final double rawD = decayBuffer[i];
              if (rawD != _cachedDecay) {
                _updateDecayCache(rawD, sLevel, sampleRate);
              }
            }
            if (isExp) {
              currentLevel += _expDecayCoeff * (sLevel - currentLevel);
            } else {
              final double linRate = sustainBuffer != null
                  ? (1.0 - sLevel) / (_dTime * sampleRate)
                  : _linDecayRate;
              currentLevel -= linRate;
            }
            if (currentLevel <= sLevel || currentLevel - sLevel <= 0.0005) {
              currentLevel = sLevel;
              currentState = .sustain;
            }

          case .sustain:
            currentLevel = sustainBuffer != null
                ? sustainBuffer[i].fastClamp(0.0, 1.0)
                : _sLevel;

          case .release:
            if (releaseBuffer != null) {
              final double rawR = releaseBuffer[i];
              if (rawR != _cachedRelease) {
                _updateReleaseCache(rawR, sampleRate);
              }
            }
            currentLevel += isExp
                ? _expReleaseCoeff * (-0.01 - currentLevel)
                : -_linReleaseRate;
            if (currentLevel <= 0.0005) {
              currentLevel = 0.0;
              currentState = .idle;
            }
        }

        output[i] = currentLevel;
      }
    }

    level = currentLevel;
    state = currentState;
    _lastGate = lastGate;
    _linearAttackRate = linAttackRate;
  }
}
