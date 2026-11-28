import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

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
  EnvelopeCurve? curve,
  double interpTime,
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
  final EnvelopeCurve curve = .exponential,
  final double interpTime = 0.02,
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
  List<Object?> get dynamicProps => [
    attack,
    decay,
    sustain,
    release,
    curve,
    interpTime,
  ];

  @override
  AdsrProcessor createProcessor() => AdsrProcessor(
    attack: attack.valueOrNull,
    decay: decay.valueOrNull,
    sustain: sustain.valueOrNull,
    release: release.valueOrNull,
    curve: curve,
    interpTime: interpTime,
  );

  @override
  AdsrParams get params => (
    attack: attack.valueOrNull,
    decay: decay.valueOrNull,
    sustain: sustain.valueOrNull,
    release: release.valueOrNull,
    curve: curve,
    interpTime: interpTime,
  );
}

class AdsrProcessor({
  /// Attack time in seconds. If null, driven by [Adsr.attackInlet].
  var double? attack = 0.01,

  /// Decay time in seconds. If null, driven by [Adsr.decayInlet].
  var double? decay = 0.1,

  /// Sustain level (0.0 to 1.0). If null, driven by [Adsr.sustainInlet].
  var double? sustain = 0.7,

  /// Release time in seconds. If null, driven by [Adsr.releaseInlet].
  var double? release = 0.3,

  /// Envelope curve style.
  var EnvelopeCurve curve = .exponential,

  /// Smoothing ramp time (seconds) for static [sustain] updates.
  var double interpTime = 0.02,
}) implements AudioProcessor {
  // ln(1.5 / (1.5 - 1.0)) = ln(3.0): crosses 1.0 at t = attack with 0.5 overshoot.
  static const double _expAttackLog = 1.0986122886681098;
  // ln(1.05 / 0.05) = ln(21.0): crosses target at t = time with 5% undershoot.
  static const double _expDecayLog = 3.044522437723423;
  static const double _expUndershoot = 0.05;

  /// Current envelope output amplitude (0.0 to 1.0).
  double level = 0.0;

  /// Active state of the envelope.
  AdsrState state = AdsrState.idle;

  /// Gate state in the previous sample (for rising/falling edge detection).
  bool _lastGate = false;

  /// Linear rate accumulator for attack when retriggered mid-flight.
  double _linearAttackRate = 0.0;

  /// Linear rate accumulator for release scaled from the level at note-off.
  double _linearReleaseRate = 0.0;

  /// Envelope level captured on gate falling edge (for release scaling).
  double _releaseStartLevel = 0.0;

  late final SmoothedValue _sustainSmoother = SmoothedValue(
    (sustain ?? 0.7).fastClamp(0.0, 1.0),
  );

  // Cached coefficients for zero-allocation steady-state processing
  double _cachedAttack = -1.0;
  double _cachedDecay = -1.0;
  double _cachedSustain = -1.0;
  double _cachedRelease = -1.0;
  double _cachedSampleRate = -1.0;

  double _aTime = 0.01;
  double _dTime = 0.1;
  double _rTime = 0.3;
  double _expAttackCoeff = 0.0;
  double _expDecayCoeff = 0.0;
  double _expReleaseCoeff = 0.0;
  double _linDecayRate = 0.0;

  @override
  void update(Object params) {
    final p = params as AdsrParams;
    attack = p.attack;
    decay = p.decay;
    sustain = p.sustain;
    release = p.release;
    if (p.curve != null) curve = p.curve!;
    interpTime = p.interpTime;

    if (p.sustain != null) {
      final clamped = p.sustain!.fastClamp(0.0, 1.0);
      if (interpTime <= 0.0) {
        _sustainSmoother.snapTo(clamped);
      } else {
        _sustainSmoother.setTarget(clamped);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _updateAttackCache(double rawAttack, double sampleRate) {
    _cachedAttack = rawAttack;
    _aTime = rawAttack > 0.0001 ? rawAttack : 0.0001;
    _expAttackCoeff = 1.0 - math.exp(-_expAttackLog / (_aTime * sampleRate));
  }

  @pragma('vm:prefer-inline')
  void _updateDecayCache(double rawDecay, double sLevel, double sampleRate) {
    _cachedDecay = rawDecay;
    _dTime = rawDecay > 0.0001 ? rawDecay : 0.0001;
    _expDecayCoeff = 1.0 - math.exp(-_expDecayLog / (_dTime * sampleRate));
    _linDecayRate = (1.0 - sLevel) / (_dTime * sampleRate);
  }

  @pragma('vm:prefer-inline')
  void _updateReleaseCache(double rawRelease, double sampleRate) {
    _cachedRelease = rawRelease;
    _rTime = rawRelease > 0.0001 ? rawRelease : 0.0001;
    _expReleaseCoeff = 1.0 - math.exp(-_expDecayLog / (_rTime * sampleRate));
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

    _sustainSmoother.configure(sampleRate: sampleRate, rampTime: interpTime);

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
    final double staticRelease = release ?? 0.3;
    final bool isSustainSettled = _sustainSmoother.isSettled;
    final double settledSustain = _sustainSmoother.current;

    if (!hasSustainSignal &&
        isSustainSettled &&
        settledSustain != _cachedSustain) {
      _cachedSustain = settledSustain;
      _cachedDecay = -1.0; // Recompute _linDecayRate for new sustain level
    }
    if (!hasAttackSignal && staticAttack != _cachedAttack) {
      _updateAttackCache(staticAttack, sampleRate);
    }
    if (!hasDecaySignal && staticDecay != _cachedDecay) {
      _updateDecayCache(staticDecay, settledSustain, sampleRate);
    }
    if (!hasReleaseSignal && staticRelease != _cachedRelease) {
      _updateReleaseCache(staticRelease, sampleRate);
    }

    double currentLevel = level;
    AdsrState currentState = state;
    bool lastGate = _lastGate;
    double linAttackRate = _linearAttackRate;
    double linReleaseRate = _linearReleaseRate;
    double releaseStartLevel = _releaseStartLevel;

    final bool isExp = curve == EnvelopeCurve.exponential;

    if (!hasAttackSignal &&
        !hasDecaySignal &&
        !hasSustainSignal &&
        !hasReleaseSignal &&
        isSustainSettled) {
      final double sLevel = settledSustain;
      final double decayTarget = sLevel - _expUndershoot * (1.0 - sLevel);
      final double aTime = _aTime;
      final double rTime = _rTime;
      final double expAttackCoeff = _expAttackCoeff;
      final double expDecayCoeff = _expDecayCoeff;
      final double expReleaseCoeff = _expReleaseCoeff;
      final double linDecayRate = _linDecayRate;

      for (int i = 0; i < output.length; i++) {
        final bool gateHigh = gateBuffer[i] > 0.0;

        // Edge detection
        if (!lastGate && gateHigh) {
          // Gate Rising Edge: Trigger Note On / Attack
          currentState = .attack;
          linAttackRate = (1.0 - currentLevel) / (aTime * sampleRate);
        } else if (lastGate && !gateHigh && currentState != .idle) {
          // Gate Falling Edge: Trigger Note Off / Release
          releaseStartLevel = currentLevel;
          if (releaseStartLevel <= 0.0) {
            currentLevel = 0.0;
            currentState = .idle;
          } else {
            currentState = .release;
            linReleaseRate = releaseStartLevel / (rTime * sampleRate);
          }
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
                ? expDecayCoeff * (decayTarget - currentLevel)
                : -linDecayRate;
            if (currentLevel <= sLevel) {
              currentLevel = sLevel;
              currentState = .sustain;
            }

          case .sustain:
            currentLevel = sLevel;

          case .release:
            currentLevel += isExp
                ? expReleaseCoeff *
                      (-_expUndershoot * releaseStartLevel - currentLevel)
                : -linReleaseRate;
            if (currentLevel <= 0.0) {
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
        final double sLevel = sustainBuffer != null
            ? sustainBuffer[i].fastClamp(0.0, 1.0)
            : _sustainSmoother.next();

        // Edge detection
        if (!lastGate && gateHigh) {
          currentState = .attack;
          final double rawA = attackBuffer != null
              ? attackBuffer[i]
              : staticAttack;
          final double aTime = rawA > 0.0001 ? rawA : 0.0001;
          linAttackRate = (1.0 - currentLevel) / (aTime * sampleRate);
        } else if (lastGate && !gateHigh && currentState != .idle) {
          releaseStartLevel = currentLevel;
          if (releaseStartLevel <= 0.0) {
            currentLevel = 0.0;
            currentState = .idle;
          } else {
            currentState = .release;
            final double rawR = releaseBuffer != null
                ? releaseBuffer[i]
                : staticRelease;
            final double rTime = rawR > 0.0001 ? rawR : 0.0001;
            linReleaseRate = releaseStartLevel / (rTime * sampleRate);
          }
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
            if (decayBuffer != null) {
              final double rawD = decayBuffer[i];
              if (rawD != _cachedDecay) {
                _updateDecayCache(rawD, sLevel, sampleRate);
              }
            }
            if (isExp) {
              final double decayTarget =
                  sLevel - _expUndershoot * (1.0 - sLevel);
              currentLevel += _expDecayCoeff * (decayTarget - currentLevel);
            } else {
              final double linRate = (1.0 - sLevel) / (_dTime * sampleRate);
              currentLevel -= linRate;
            }
            if (currentLevel <= sLevel) {
              currentLevel = sLevel;
              currentState = .sustain;
            }

          case .sustain:
            currentLevel = sLevel;

          case .release:
            if (releaseBuffer != null) {
              final double rawR = releaseBuffer[i];
              if (rawR != _cachedRelease) {
                _updateReleaseCache(rawR, sampleRate);
              }
              linReleaseRate = releaseStartLevel / (_rTime * sampleRate);
            }
            currentLevel += isExp
                ? _expReleaseCoeff *
                      (-_expUndershoot * releaseStartLevel - currentLevel)
                : -linReleaseRate;
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
    _lastGate = lastGate;
    _linearAttackRate = linAttackRate;
    _linearReleaseRate = linReleaseRate;
    _releaseStartLevel = releaseStartLevel;
  }
}
