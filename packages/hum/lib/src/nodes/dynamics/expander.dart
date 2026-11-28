import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Parameter bag for updating an [ExpanderProcessor] in-place.
typedef ExpanderParams = ({
  double? threshold,
  double? ratio,
  double? range,
  double? attack,
  double? hold,
  double? release,
  double? knee,
  double? hysteresis,
  bool hasSidechain,
});

/// A digital feed-forward downward expander for attenuating signals below a threshold.
///
/// Implements a 4-stage feed-forward downward dynamics architecture:
/// 1. **Peak / Linked Multi-Channel Level Detector**: Detects max absolute peak amplitude
///    across all input channels (or an external [sidechain] signal if provided). Stereo linking
///    presents a unified gain envelope across channels, preserving the stereo image.
/// 2. **Hysteresis & Hold State Machine**: Optionally separates open ([threshold]) and close
///    (`threshold - hysteresis`) levels and holds the gate open for [hold] seconds before
///    engaging release, preventing chatter on decaying signals.
/// 3. **Quadratic Soft-Knee Downward Gain Computer**: Attenuates signals below threshold
///    according to [ratio] (`1.0` = unity, `2.0` = 2:1 expansion, `double.infinity` = hard gate),
///    clamped to the maximum attenuation floor [range].
/// 4. **Decoupled 1-Pole Ballistics Smoothing**: Smooths gain in the dB domain with independent
///    [attack] (opening) and [release] (closing) time constants.
///
/// For a dedicated noise gate with gate-centric defaults (infinite ratio, hard knee, hysteresis,
/// and hold), see [NoiseGate], which shares [ExpanderProcessor].
class Expander({
  required final List<Outlet> channels,
  final Outlet? sidechain,
  final ControlParam<double> threshold = const .value(-40.0),
  final ControlParam<double> ratio = const .value(2.0),
  final ControlParam<double> range = const .value(-60.0),
  final ControlParam<double> attack = const .value(0.005),
  final ControlParam<double> hold = const .value(0.020),
  final ControlParam<double> release = const .value(0.100),
  final ControlParam<double> knee = const .value(6.0),
  final ControlParam<double> hysteresis = const .value(0.0),
}) extends AudioNode<ExpanderProcessor> {
  factory mono(
    Outlet input, {
    Outlet? sidechain,
    ControlParam<double> threshold = const .value(-40.0),
    ControlParam<double> ratio = const .value(2.0),
    ControlParam<double> range = const .value(-60.0),
    ControlParam<double> attack = const .value(0.005),
    ControlParam<double> hold = const .value(0.020),
    ControlParam<double> release = const .value(0.100),
    ControlParam<double> knee = const .value(6.0),
    ControlParam<double> hysteresis = const .value(0.0),
  }) => Expander(
    channels: [input],
    sidechain: sidechain,
    threshold: threshold,
    ratio: ratio,
    range: range,
    attack: attack,
    hold: hold,
    release: release,
    knee: knee,
    hysteresis: hysteresis,
  );

  factory stereo(
    Outlet left,
    Outlet right, {
    Outlet? sidechain,
    ControlParam<double> threshold = const .value(-40.0),
    ControlParam<double> ratio = const .value(2.0),
    ControlParam<double> range = const .value(-60.0),
    ControlParam<double> attack = const .value(0.005),
    ControlParam<double> hold = const .value(0.020),
    ControlParam<double> release = const .value(0.100),
    ControlParam<double> knee = const .value(6.0),
    ControlParam<double> hysteresis = const .value(0.0),
  }) => Expander(
    channels: [left, right],
    sidechain: sidechain,
    threshold: threshold,
    ratio: ratio,
    range: range,
    attack: attack,
    hold: hold,
    release: release,
    knee: knee,
    hysteresis: hysteresis,
  );

  static const thresholdInlet = 0;
  static const ratioInlet = 1;
  static const rangeInlet = 2;
  static const attackInlet = 3;
  static const holdInlet = 4;
  static const releaseInlet = 5;
  static const kneeInlet = 6;
  static const hysteresisInlet = 7;
  static const sidechainInlet = 8;
  static const audioInletOffset = 9;

  int get numChannels => channels.length;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: thresholdInlet, source: threshold.outletOrNull),
    Inlet(node: this, index: ratioInlet, source: ratio.outletOrNull),
    Inlet(node: this, index: rangeInlet, source: range.outletOrNull),
    Inlet(node: this, index: attackInlet, source: attack.outletOrNull),
    Inlet(node: this, index: holdInlet, source: hold.outletOrNull),
    Inlet(node: this, index: releaseInlet, source: release.outletOrNull),
    Inlet(node: this, index: kneeInlet, source: knee.outletOrNull),
    Inlet(node: this, index: hysteresisInlet, source: hysteresis.outletOrNull),
    Inlet(node: this, index: sidechainInlet, source: sidechain),
    for (int i = 0; i < channels.length; i++)
      Inlet(node: this, index: audioInletOffset + i, source: channels[i]),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(channels.length, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeParamError(param: 'channels', error: 'must not be empty'),
    if (ratio.valueOrNull != null && ratio.valueOrNull! < 1.0)
      const AudioNodeParamError(param: 'ratio', error: 'must be >= 1.0'),
    if (range.valueOrNull != null && range.valueOrNull! > 0.0)
      const AudioNodeParamError(param: 'range', error: 'must be <= 0.0'),
    if (attack.valueOrNull != null && attack.valueOrNull! < 0.0)
      const AudioNodeParamError(param: 'attack', error: 'must be non-negative'),
    if (hold.valueOrNull != null && hold.valueOrNull! < 0.0)
      const AudioNodeParamError(param: 'hold', error: 'must be non-negative'),
    if (release.valueOrNull != null && release.valueOrNull! < 0.0)
      const AudioNodeParamError(
        param: 'release',
        error: 'must be non-negative',
      ),
    if (knee.valueOrNull != null && knee.valueOrNull! < 0.0)
      const AudioNodeParamError(param: 'knee', error: 'must be non-negative'),
    if (hysteresis.valueOrNull != null && hysteresis.valueOrNull! < 0.0)
      const AudioNodeParamError(
        param: 'hysteresis',
        error: 'must be non-negative',
      ),
  ];

  @override
  List<Object?> get fixedProps => [sidechain != null];

  @override
  List<Object?> get dynamicProps => [
    threshold,
    ratio,
    range,
    attack,
    hold,
    release,
    knee,
    hysteresis,
  ];

  @override
  ExpanderProcessor createProcessor() => ExpanderProcessor(
    numChannels: numChannels,
    threshold: threshold.valueOrNull,
    ratio: ratio.valueOrNull,
    range: range.valueOrNull,
    attack: attack.valueOrNull,
    hold: hold.valueOrNull,
    release: release.valueOrNull,
    knee: knee.valueOrNull,
    hysteresis: hysteresis.valueOrNull,
    hasSidechain: sidechain != null,
  );

  @override
  ExpanderParams get params => (
    threshold: threshold.valueOrNull,
    ratio: ratio.valueOrNull,
    range: range.valueOrNull,
    attack: attack.valueOrNull,
    hold: hold.valueOrNull,
    release: release.valueOrNull,
    knee: knee.valueOrNull,
    hysteresis: hysteresis.valueOrNull,
    hasSidechain: sidechain != null,
  );
}

/// A feed-forward noise gate with hysteresis, hold time, and attenuation floor.
///
/// Basically just an alias for [Expander] with an infinite ratio and hard knee:
/// - Opens when the level reaches [threshold] (attacking over [attack] seconds).
/// - Remains open while above `threshold - hysteresis` and for [hold] seconds after
///   dropping below the close threshold.
/// - Closes smoothly over [release] seconds down to the [range] attenuation floor
///   (use `double.negativeInfinity` for complete mute).
class NoiseGate({
  required super.channels,
  super.sidechain,
  super.threshold = const .value(-40.0),
  super.hysteresis = const .value(4.0),
  super.range = const .value(-80.0),
  super.attack = const .value(0.002),
  super.hold = const .value(0.050),
  super.release = const .value(0.100),
}) extends Expander {
  this : super(ratio: const .value(double.infinity), knee: const .value(0.0));

  factory mono(
    Outlet input, {
    Outlet? sidechain,
    ControlParam<double> threshold = const .value(-40.0),
    ControlParam<double> hysteresis = const .value(4.0),
    ControlParam<double> range = const .value(-80.0),
    ControlParam<double> attack = const .value(0.002),
    ControlParam<double> hold = const .value(0.050),
    ControlParam<double> release = const .value(0.100),
  }) => NoiseGate(
    channels: [input],
    sidechain: sidechain,
    threshold: threshold,
    hysteresis: hysteresis,
    range: range,
    attack: attack,
    hold: hold,
    release: release,
  );

  factory stereo(
    Outlet left,
    Outlet right, {
    Outlet? sidechain,
    ControlParam<double> threshold = const .value(-40.0),
    ControlParam<double> hysteresis = const .value(4.0),
    ControlParam<double> range = const .value(-80.0),
    ControlParam<double> attack = const .value(0.002),
    ControlParam<double> hold = const .value(0.050),
    ControlParam<double> release = const .value(0.100),
  }) => NoiseGate(
    channels: [left, right],
    sidechain: sidechain,
    threshold: threshold,
    hysteresis: hysteresis,
    range: range,
    attack: attack,
    hold: hold,
    release: release,
  );
}

/// Processor implementing linked multi-channel downward expansion and noise gating.
class ExpanderProcessor({
  required final int numChannels,
  var double? threshold = -40.0,
  var double? ratio = 2.0,
  var double? range = -60.0,
  var double? attack = 0.005,
  var double? hold = 0.020,
  var double? release = 0.100,
  var double? knee = 6.0,
  var double? hysteresis = 0.0,
  var bool hasSidechain = false,
}) implements AudioProcessor {
  static const double _minFloorDb = -120.0;

  double _envelopeDb = 0.0;
  bool _isOpen = false;
  int _holdSamplesRemaining = 0;

  double _lastSampleRate = 0.0;
  double _lastAttack = -1.0;
  double _lastRelease = -1.0;
  double _cachedAlphaAttack = 0.0;
  double _cachedAlphaRelease = 0.0;

  /// Current smoothed gain envelope in decibels (always `<= 0.0`).
  double get envelopeDb => _envelopeDb;

  /// Current gain reduction in decibels (positive value representing attenuation).
  double get gainReductionDb => -_envelopeDb;

  /// Whether the gate / expander detector is currently in the open state.
  bool get isOpen => _isOpen;

  @override
  void update(Object params) {
    final p = params as ExpanderParams;
    threshold = p.threshold;
    ratio = p.ratio;
    range = p.range;
    attack = p.attack;
    hold = p.hold;
    release = p.release;
    knee = p.knee;
    hysteresis = p.hysteresis;
    hasSidechain = p.hasSidechain;
  }

  @pragma('vm:prefer-inline')
  static double _calcAlpha(double timeSeconds, double sampleRate) {
    if (timeSeconds <= 0.0 || sampleRate <= 0.0) return 0.0;
    return math.exp(-1.0 / (sampleRate * timeSeconds));
  }

  @pragma('vm:prefer-inline')
  static double _clampRangeDb(double rangeDb) {
    if (rangeDb >= 0.0) return 0.0;
    if (rangeDb <= _minFloorDb || rangeDb.isInfinite) return _minFloorDb;
    return rangeDb;
  }

  @pragma('vm:prefer-inline')
  static double _computeGainReductionDb(
    double inputDb,
    double thresholdDb,
    double ratio,
    double kneeDb,
    double effectiveRangeDb,
  ) {
    if (ratio <= 1.0 || effectiveRangeDb >= 0.0) return 0.0;

    // Positive when signal is below threshold.
    final under = thresholdDb - inputDb;

    double grDb;
    if (kneeDb <= 0.0 || ratio.isInfinite) {
      if (under <= 0.0) return 0.0;
      grDb = ratio.isInfinite ? effectiveRangeDb : -(ratio - 1.0) * under;
    } else {
      final halfKnee = kneeDb * 0.5;
      if (under <= -halfKnee) {
        return 0.0;
      } else if (under >= halfKnee) {
        grDb = -(ratio - 1.0) * under;
      } else {
        // C1-smooth quadratic spline matching 0 derivative at -W/2 and -(ratio-1) at +W/2
        final delta = under + halfKnee;
        grDb = -((ratio - 1.0) * delta * delta) / (2.0 * kneeDb);
      }
    }

    return grDb < effectiveRangeDb ? effectiveRangeDb : grDb;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final sampleRate = context.sampleRate.toDouble();

    final sidechainBuf = hasSidechain ? inputs[Expander.sidechainInlet] : null;

    final staticThreshold = threshold;
    final staticRatio = ratio;
    final staticRange = range;
    final staticAttack = attack;
    final staticHold = hold;
    final staticRelease = release;
    final staticKnee = knee;
    final staticHysteresis = hysteresis;

    final threshBuf = staticThreshold == null
        ? inputs[Expander.thresholdInlet]
        : null;
    final ratioBuf = staticRatio == null ? inputs[Expander.ratioInlet] : null;
    final rangeBuf = staticRange == null ? inputs[Expander.rangeInlet] : null;
    final attackBuf = staticAttack == null
        ? inputs[Expander.attackInlet]
        : null;
    final holdBuf = staticHold == null ? inputs[Expander.holdInlet] : null;
    final releaseBuf = staticRelease == null
        ? inputs[Expander.releaseInlet]
        : null;
    final kneeBuf = staticKnee == null ? inputs[Expander.kneeInlet] : null;
    final hystBuf = staticHysteresis == null
        ? inputs[Expander.hysteresisInlet]
        : null;

    final isStaticParams =
        threshBuf == null &&
        ratioBuf == null &&
        rangeBuf == null &&
        attackBuf == null &&
        holdBuf == null &&
        releaseBuf == null &&
        kneeBuf == null &&
        hystBuf == null;

    final double currentThreshold = staticThreshold ?? -40.0;
    final double currentRatio = staticRatio ?? 2.0;
    final double currentRange = staticRange ?? -60.0;
    final double currentAttack = staticAttack ?? 0.005;
    final double currentHold = staticHold ?? 0.020;
    final double currentRelease = staticRelease ?? 0.100;
    final double currentKnee = staticKnee ?? 6.0;
    final double currentHysteresis = staticHysteresis ?? 0.0;

    double envDb = _envelopeDb;
    bool open = _isOpen;
    int holdRemaining = _holdSamplesRemaining;

    if (isStaticParams) {
      if (sampleRate != _lastSampleRate ||
          currentAttack != _lastAttack ||
          currentRelease != _lastRelease) {
        _lastSampleRate = sampleRate;
        _lastAttack = currentAttack;
        _lastRelease = currentRelease;
        _cachedAlphaAttack = _calcAlpha(currentAttack, sampleRate);
        _cachedAlphaRelease = _calcAlpha(currentRelease, sampleRate);
      }

      final alphaAtt = _cachedAlphaAttack;
      final alphaRel = _cachedAlphaRelease;
      final t = currentThreshold;
      final r = currentRatio;
      final rawRange = currentRange;
      final effRange = _clampRangeDb(rawRange);
      final isFullMute = rawRange.isInfinite && rawRange < 0.0;
      final holdSamples = currentHold > 0.0
          ? (currentHold * sampleRate).round()
          : 0;
      final k = currentKnee;
      final h = currentHysteresis > 0.0 ? currentHysteresis : 0.0;
      final closeThreshold = t - h;
      final useStateMachine = h > 0.0 || holdSamples > 0;

      for (int i = 0; i < length; i++) {
        double peak = 0.0;
        if (sidechainBuf != null) {
          peak = sidechainBuf[i].abs();
        } else {
          for (int c = 0; c < numChannels; c++) {
            final val = inputs[Expander.audioInletOffset + c][i].abs();
            if (val > peak) peak = val;
          }
        }

        final inputDb = gainToDb(peak);

        final double targetDb;
        if (!useStateMachine) {
          open = inputDb >= t;
          targetDb = _computeGainReductionDb(inputDb, t, r, k, effRange);
        } else {
          if (open) {
            if (inputDb >= closeThreshold) {
              holdRemaining = holdSamples;
            } else if (holdRemaining > 0) {
              holdRemaining--;
            } else {
              open = false;
            }
          } else if (inputDb >= t) {
            open = true;
            holdRemaining = holdSamples;
          }

          targetDb = open
              ? 0.0
              : _computeGainReductionDb(inputDb, t, r, k, effRange);
        }

        // Inverted ballistics relative to compressor:
        // attack = opening (gain rising toward 0 dB), release = closing (gain falling).
        if (targetDb > envDb) {
          envDb = alphaAtt * envDb + (1.0 - alphaAtt) * targetDb;
        } else {
          envDb = alphaRel * envDb + (1.0 - alphaRel) * targetDb;
        }

        if (envDb.abs() < 1e-6) {
          envDb = 0.0;
        }

        final double gain = (isFullMute && envDb <= _minFloorDb + 1e-4)
            ? 0.0
            : dbToGain(envDb);

        for (int c = 0; c < numChannels; c++) {
          outputs[c][i] = inputs[Expander.audioInletOffset + c][i] * gain;
        }
      }
    } else {
      for (int i = 0; i < length; i++) {
        final t = threshBuf != null ? threshBuf[i] : currentThreshold;
        final r = ratioBuf != null ? ratioBuf[i] : currentRatio;
        final rawRange = rangeBuf != null ? rangeBuf[i] : currentRange;
        final att = attackBuf != null ? attackBuf[i] : currentAttack;
        final hld = holdBuf != null ? holdBuf[i] : currentHold;
        final rel = releaseBuf != null ? releaseBuf[i] : currentRelease;
        final k = kneeBuf != null ? kneeBuf[i] : currentKnee;
        final rawH = hystBuf != null ? hystBuf[i] : currentHysteresis;

        final alphaAtt = _calcAlpha(att, sampleRate);
        final alphaRel = _calcAlpha(rel, sampleRate);
        final effRange = _clampRangeDb(rawRange);
        final isFullMute = rawRange.isInfinite && rawRange < 0.0;
        final holdSamples = hld > 0.0 ? (hld * sampleRate).round() : 0;
        final h = rawH > 0.0 ? rawH : 0.0;
        final closeThreshold = t - h;
        final useStateMachine = h > 0.0 || holdSamples > 0;

        double peak = 0.0;
        if (sidechainBuf != null) {
          peak = sidechainBuf[i].abs();
        } else {
          for (int c = 0; c < numChannels; c++) {
            final val = inputs[Expander.audioInletOffset + c][i].abs();
            if (val > peak) peak = val;
          }
        }

        final inputDb = gainToDb(peak);

        final double targetDb;
        if (!useStateMachine) {
          open = inputDb >= t;
          targetDb = _computeGainReductionDb(inputDb, t, r, k, effRange);
        } else {
          if (open) {
            if (inputDb >= closeThreshold) {
              holdRemaining = holdSamples;
            } else if (holdRemaining > 0) {
              holdRemaining--;
            } else {
              open = false;
            }
          } else if (inputDb >= t) {
            open = true;
            holdRemaining = holdSamples;
          }

          targetDb = open
              ? 0.0
              : _computeGainReductionDb(inputDb, t, r, k, effRange);
        }

        if (targetDb > envDb) {
          envDb = alphaAtt * envDb + (1.0 - alphaAtt) * targetDb;
        } else {
          envDb = alphaRel * envDb + (1.0 - alphaRel) * targetDb;
        }

        if (envDb.abs() < 1e-6) {
          envDb = 0.0;
        }

        final double gain = (isFullMute && envDb <= _minFloorDb + 1e-4)
            ? 0.0
            : dbToGain(envDb);

        for (int c = 0; c < numChannels; c++) {
          outputs[c][i] = inputs[Expander.audioInletOffset + c][i] * gain;
        }
      }
    }

    _envelopeDb = envDb;
    _isOpen = open;
    _holdSamplesRemaining = holdRemaining;
  }
}

extension OutletExpanderExtension on Outlet {
  /// Applies downward dynamic range expansion to this outlet.
  Expander expand({
    Outlet? sidechain,
    ControlParam<double> threshold = const .value(-40.0),
    ControlParam<double> ratio = const .value(2.0),
    ControlParam<double> range = const .value(-60.0),
    ControlParam<double> attack = const .value(0.005),
    ControlParam<double> hold = const .value(0.020),
    ControlParam<double> release = const .value(0.100),
    ControlParam<double> knee = const .value(6.0),
    ControlParam<double> hysteresis = const .value(0.0),
  }) => .mono(
    this,
    sidechain: sidechain,
    threshold: threshold,
    ratio: ratio,
    range: range,
    attack: attack,
    hold: hold,
    release: release,
    knee: knee,
    hysteresis: hysteresis,
  );

  /// Applies a noise gate to this outlet.
  NoiseGate gate({
    Outlet? sidechain,
    ControlParam<double> threshold = const .value(-40.0),
    ControlParam<double> hysteresis = const .value(4.0),
    ControlParam<double> range = const .value(-80.0),
    ControlParam<double> attack = const .value(0.002),
    ControlParam<double> hold = const .value(0.050),
    ControlParam<double> release = const .value(0.100),
  }) => .mono(
    this,
    sidechain: sidechain,
    threshold: threshold,
    hysteresis: hysteresis,
    range: range,
    attack: attack,
    hold: hold,
    release: release,
  );
}
