import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Parameter bag for updating a [CompressorProcessor] in-place.
typedef CompressorParams = ({
  double? threshold,
  double? ratio,
  double? attack,
  double? release,
  double? knee,
  double? makeupGain,
  bool hasSidechain,
});

/// A studio-grade digital feed-forward dynamic range compressor and brickwall limiter.
///
/// Implements a 4-stage digital feed-forward architecture:
/// 1. **Peak / Linked Multi-Channel Level Detector**: Detects max absolute peak amplitude
///    across all input channels (or an external [sidechain] signal if provided). Stereo linking
///    prevents stereo image drifting under asymmetric channel dynamics.
/// 2. **Decibel Domain Static Characteristics**: Converts signal amplitude to decibels:
///    `gainToDb(peak)`.
/// 3. **Quadratic Soft-Knee Gain Computer**:
///    - When input is below knee (`overshoot <= -knee/2`): Gain reduction is 0 dB.
///    - When input is above knee (`overshoot >= +knee/2`): Gain reduction follows ratio:
///      `-overshoot * (1 - 1 / ratio)`.
///    - When inside knee (`-knee/2 < overshoot < +knee/2`): Smooth quadratic spline
///      `-((1 - 1 / ratio) * (overshoot + knee/2)^2) / (2 * knee)` guarantees continuous
///      first derivative (C1-smooth), eliminating harmonic distortion at threshold transitions.
/// 4. **Decoupled 1-Pole Ballistics Smoothing**:
///    Smooths gain reduction in the dB domain with independent [attack] and [release]
///    time constants (`alpha = exp(-1 / (sampleRate * tau))`).
/// 5. **VCA & Makeup Gain**:
///    Converts smoothed reduction plus [makeupGain] to linear gain factor and multiplies
///    each audio channel.
class const Compressor({
  required final List<Outlet> channels,
  final Outlet? sidechain,
  final ControlParam<double> threshold = const .value(-18.0),
  final ControlParam<double> ratio = const .value(4.0),
  final ControlParam<double> attack = const .value(0.010),
  final ControlParam<double> release = const .value(0.100),
  final ControlParam<double> knee = const .value(6.0),
  final ControlParam<double> makeupGain = const .value(0.0),
}) extends AudioNode<CompressorProcessor> {
  factory mono(
    Outlet input, {
    Outlet? sidechain,
    ControlParam<double> threshold = const .value(-18.0),
    ControlParam<double> ratio = const .value(4.0),
    ControlParam<double> attack = const .value(0.010),
    ControlParam<double> release = const .value(0.100),
    ControlParam<double> knee = const .value(6.0),
    ControlParam<double> makeupGain = const .value(0.0),
  }) => Compressor(
    channels: [input],
    sidechain: sidechain,
    threshold: threshold,
    ratio: ratio,
    attack: attack,
    release: release,
    knee: knee,
    makeupGain: makeupGain,
  );

  factory stereo(
    Outlet left,
    Outlet right, {
    Outlet? sidechain,
    ControlParam<double> threshold = const .value(-18.0),
    ControlParam<double> ratio = const .value(4.0),
    ControlParam<double> attack = const .value(0.010),
    ControlParam<double> release = const .value(0.100),
    ControlParam<double> knee = const .value(6.0),
    ControlParam<double> makeupGain = const .value(0.0),
  }) => Compressor(
    channels: [left, right],
    sidechain: sidechain,
    threshold: threshold,
    ratio: ratio,
    attack: attack,
    release: release,
    knee: knee,
    makeupGain: makeupGain,
  );

  /// Brickwall peak limiter preset with infinite ratio, fast attack, and hard knee.
  factory limiter(
    List<Outlet> channels, {
    ControlParam<double> threshold = const .value(-0.5),
    ControlParam<double> attack = const .value(0.001),
    ControlParam<double> release = const .value(0.050),
    ControlParam<double> knee = const .value(0.0),
    ControlParam<double> makeupGain = const .value(0.0),
  }) => Compressor(
    channels: channels,
    threshold: threshold,
    ratio: const .value(double.infinity),
    attack: attack,
    release: release,
    knee: knee,
    makeupGain: makeupGain,
  );

  static const thresholdInlet = 0;
  static const ratioInlet = 1;
  static const attackInlet = 2;
  static const releaseInlet = 3;
  static const kneeInlet = 4;
  static const makeupGainInlet = 5;
  static const sidechainInlet = 6;
  static const audioInletOffset = 7;

  int get numChannels => channels.length;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: thresholdInlet, source: threshold.outletOrNull),
    Inlet(node: this, index: ratioInlet, source: ratio.outletOrNull),
    Inlet(node: this, index: attackInlet, source: attack.outletOrNull),
    Inlet(node: this, index: releaseInlet, source: release.outletOrNull),
    Inlet(node: this, index: kneeInlet, source: knee.outletOrNull),
    Inlet(node: this, index: makeupGainInlet, source: makeupGain.outletOrNull),
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
    if (attack.valueOrNull != null && attack.valueOrNull! < 0.0)
      const AudioNodeParamError(param: 'attack', error: 'must be non-negative'),
    if (release.valueOrNull != null && release.valueOrNull! < 0.0)
      const AudioNodeParamError(
        param: 'release',
        error: 'must be non-negative',
      ),
    if (knee.valueOrNull != null && knee.valueOrNull! < 0.0)
      const AudioNodeParamError(param: 'knee', error: 'must be non-negative'),
  ];

  @override
  bool canUpdate(covariant Compressor newNode) =>
      super.canUpdate(newNode) &&
      numChannels == newNode.numChannels &&
      (sidechain != null) == (newNode.sidechain != null);

  @override
  CompressorProcessor createProcessor() => CompressorProcessor(
    numChannels: numChannels,
    threshold: threshold.valueOrNull,
    ratio: ratio.valueOrNull,
    attack: attack.valueOrNull,
    release: release.valueOrNull,
    knee: knee.valueOrNull,
    makeupGain: makeupGain.valueOrNull,
    hasSidechain: sidechain != null,
  );

  @override
  CompressorParams get params => (
    threshold: threshold.valueOrNull,
    ratio: ratio.valueOrNull,
    attack: attack.valueOrNull,
    release: release.valueOrNull,
    knee: knee.valueOrNull,
    makeupGain: makeupGain.valueOrNull,
    hasSidechain: sidechain != null,
  );
}

/// Processor implementing linked multi-channel digital feed-forward dynamic range compression.
class CompressorProcessor({
  required final int numChannels,
  var double? threshold = -18.0,
  var double? ratio = 4.0,
  var double? attack = 0.010,
  var double? release = 0.100,
  var double? knee = 6.0,
  var double? makeupGain = 0.0,
  var bool hasSidechain = false,
}) implements AudioProcessor {
  double _envelopeDb = 0.0;
  double _lastSampleRate = 0.0;
  double _lastAttack = -1.0;
  double _lastRelease = -1.0;
  double _cachedAlphaAttack = 0.0;
  double _cachedAlphaRelease = 0.0;

  /// Current smoothed gain reduction envelope in decibels (typically <= 0.0 dB).
  double get envelopeDb => _envelopeDb;

  /// Current gain reduction in decibels (positive value representing attenuation, e.g. 6.0 dB reduction).
  double get gainReductionDb => -_envelopeDb;

  @override
  void update(Object params) {
    final p = params as CompressorParams;
    threshold = p.threshold;
    ratio = p.ratio;
    attack = p.attack;
    release = p.release;
    knee = p.knee;
    makeupGain = p.makeupGain;
    hasSidechain = p.hasSidechain;
  }

  @pragma('vm:prefer-inline')
  static double _calcAlpha(double timeSeconds, double sampleRate) {
    if (timeSeconds <= 0.0 || sampleRate <= 0.0) return 0.0;
    return math.exp(-1.0 / (sampleRate * timeSeconds));
  }

  @pragma('vm:prefer-inline')
  static double _computeGainReductionDb(
    double inputDb,
    double thresholdDb,
    double ratio,
    double kneeDb,
  ) {
    if (ratio <= 1.0) return 0.0;
    final overshoot = inputDb - thresholdDb;

    // Hard knee
    if (kneeDb <= 0.0) {
      if (overshoot <= 0.0) return 0.0;
      final slope = ratio.isInfinite ? 1.0 : (1.0 - 1.0 / ratio);
      return -overshoot * slope;
    }

    // Quadratic soft knee
    final halfKnee = kneeDb * 0.5;
    if (overshoot <= -halfKnee) {
      return 0.0;
    } else if (overshoot >= halfKnee) {
      final slope = ratio.isInfinite ? 1.0 : (1.0 - 1.0 / ratio);
      return -overshoot * slope;
    } else {
      // Inside knee: quadratic spline matching 0 derivative at -W/2 and slope at +W/2
      final slope = ratio.isInfinite ? 1.0 : (1.0 - 1.0 / ratio);
      final delta = overshoot + halfKnee;
      return -(slope * delta * delta) / (2.0 * kneeDb);
    }
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final sampleRate = context.sampleRate.toDouble();

    final isCompiled =
        inputs.length >= Compressor.audioInletOffset + numChannels;
    final int audioOffset = isCompiled ? Compressor.audioInletOffset : 0;

    final sidechainBuf = isCompiled && hasSidechain
        ? inputs[Compressor.sidechainInlet]
        : null;

    final staticThreshold = threshold;
    final staticRatio = ratio;
    final staticAttack = attack;
    final staticRelease = release;
    final staticKnee = knee;
    final staticMakeup = makeupGain;

    final threshBuf = isCompiled && staticThreshold == null
        ? inputs[Compressor.thresholdInlet]
        : null;
    final ratioBuf = isCompiled && staticRatio == null
        ? inputs[Compressor.ratioInlet]
        : null;
    final attackBuf = isCompiled && staticAttack == null
        ? inputs[Compressor.attackInlet]
        : null;
    final releaseBuf = isCompiled && staticRelease == null
        ? inputs[Compressor.releaseInlet]
        : null;
    final kneeBuf = isCompiled && staticKnee == null
        ? inputs[Compressor.kneeInlet]
        : null;
    final makeupBuf = isCompiled && staticMakeup == null
        ? inputs[Compressor.makeupGainInlet]
        : null;

    final isStaticParams =
        threshBuf == null &&
        ratioBuf == null &&
        attackBuf == null &&
        releaseBuf == null &&
        kneeBuf == null &&
        makeupBuf == null;

    final double currentThreshold = staticThreshold ?? -18.0;
    final double currentRatio = staticRatio ?? 4.0;
    final double currentAttack = staticAttack ?? 0.010;
    final double currentRelease = staticRelease ?? 0.100;
    final double currentKnee = staticKnee ?? 6.0;
    final double currentMakeup = staticMakeup ?? 0.0;

    double envDb = _envelopeDb;

    if (isStaticParams) {
      // Fast path: static scalar parameters
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
      final k = currentKnee;
      final m = currentMakeup;

      for (int i = 0; i < length; i++) {
        // Level detection (sidechain or stereo-linked peak)
        double peak = 0.0;
        if (sidechainBuf != null) {
          peak = sidechainBuf[i].abs();
        } else {
          for (int c = 0; c < numChannels; c++) {
            final val = inputs[audioOffset + c][i].abs();
            if (val > peak) peak = val;
          }
        }

        final inputDb = gainToDb(peak);

        // Static gain reduction in dB
        final targetDb = _computeGainReductionDb(inputDb, t, r, k);

        // Decoupled 1-pole ballistics smoothing
        if (targetDb < envDb) {
          envDb = alphaAtt * envDb + (1.0 - alphaAtt) * targetDb;
        } else {
          envDb = alphaRel * envDb + (1.0 - alphaRel) * targetDb;
        }

        if (envDb.abs() < 1e-6) {
          envDb = 0.0;
        }

        // Total gain and VCA application
        final totalGainDb = envDb + m;
        final gain = dbToGain(totalGainDb);

        for (int c = 0; c < numChannels; c++) {
          outputs[c][i] = inputs[audioOffset + c][i] * gain;
        }
      }
    } else {
      // Audio-rate modulated parameters path
      for (int i = 0; i < length; i++) {
        final t = threshBuf != null ? threshBuf[i] : currentThreshold;
        final r = ratioBuf != null ? ratioBuf[i] : currentRatio;
        final att = attackBuf != null ? attackBuf[i] : currentAttack;
        final rel = releaseBuf != null ? releaseBuf[i] : currentRelease;
        final k = kneeBuf != null ? kneeBuf[i] : currentKnee;
        final m = makeupBuf != null ? makeupBuf[i] : currentMakeup;

        final alphaAtt = _calcAlpha(att, sampleRate);
        final alphaRel = _calcAlpha(rel, sampleRate);

        // Level detection
        double peak = 0.0;
        if (sidechainBuf != null) {
          peak = sidechainBuf[i].abs();
        } else {
          for (int c = 0; c < numChannels; c++) {
            final val = inputs[audioOffset + c][i].abs();
            if (val > peak) peak = val;
          }
        }

        final inputDb = gainToDb(peak);

        // Static gain reduction
        final targetDb = _computeGainReductionDb(inputDb, t, r, k);

        //  Smoothing
        if (targetDb < envDb) {
          envDb = alphaAtt * envDb + (1.0 - alphaAtt) * targetDb;
        } else {
          envDb = alphaRel * envDb + (1.0 - alphaRel) * targetDb;
        }

        if (envDb.abs() < 1e-6) {
          envDb = 0.0;
        }

        //  VCA
        final totalGainDb = envDb + m;
        final gain = dbToGain(totalGainDb);

        for (int c = 0; c < numChannels; c++) {
          outputs[c][i] = inputs[audioOffset + c][i] * gain;
        }
      }
    }

    _envelopeDb = envDb;
  }
}

extension OutletCompressorExtension on Outlet {
  /// Applies dynamic range compression to this outlet.
  Compressor compress({
    Outlet? sidechain,
    ControlParam<double> threshold = const .value(-18.0),
    ControlParam<double> ratio = const .value(4.0),
    ControlParam<double> attack = const .value(0.010),
    ControlParam<double> release = const .value(0.100),
    ControlParam<double> knee = const .value(6.0),
    ControlParam<double> makeupGain = const .value(0.0),
  }) => .mono(
    this,
    sidechain: sidechain,
    threshold: threshold,
    ratio: ratio,
    attack: attack,
    release: release,
    knee: knee,
    makeupGain: makeupGain,
  );

  /// Applies peak limiting to this outlet.
  Compressor limit({
    ControlParam<double> threshold = const .value(-0.5),
    ControlParam<double> attack = const .value(0.001),
    ControlParam<double> release = const .value(0.050),
    ControlParam<double> knee = const .value(0.0),
    ControlParam<double> makeupGain = const .value(0.0),
  }) => .limiter(
    [this],
    threshold: threshold,
    attack: attack,
    release: release,
    knee: knee,
    makeupGain: makeupGain,
  );
}
