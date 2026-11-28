import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef KarplusStrongParams = ({
  double? frequency,
  double? feedback,
  double? pickHardness,
  double? pickPosition,
  double? damping,
  double interpTime,
});

/// Plucked-string physical modeling synthesis node using extended Karplus-Strong.
///
/// Supports:
/// - **Pick Hardness (`pickHardness`)**: Shapes the initial noise burst with a
///   1-pole low-pass filter (`0.0` = soft thumb, `1.0` = bright plectrum).
/// - **Pick Position (`pickPosition`)**: Comb-filters the excitation at a
///   fractional string position in `(0.0, 1.0)` (`0.5` = middle/neck hollow
///   tone cancelling even harmonics, near `0.0` or `1.0` = bright bridge twang).
/// - **Damping (`damping`)**: Variable 1-pole loop damping and palm-mute
///   attenuation (`0.0` = bright/undamped, `0.5` = warm acoustic decay,
///   `1.0` = heavy palm mute) with phase-delay pitch compensation and
///   clickless parameter smoothing.
class KarplusStrong({
  required final Outlet gate,
  final ControlParam<double> frequency = const .value(440.0),
  final ControlParam<double> feedback = const .value(0.99),
  final ControlParam<double> pickHardness = const .value(0.8),
  final ControlParam<double> pickPosition = const .value(0.25),
  final ControlParam<double> damping = const .value(0.5),
  final double interpTime = 0.02,
}) extends AudioNode<KarplusStrongProcessor> {
  static const gateInlet = 0;
  static const frequencyInlet = 1;
  static const feedbackInlet = 2;
  static const pickHardnessInlet = 3;
  static const pickPositionInlet = 4;
  static const dampingInlet = 5;
  static const outputOutlet = 0;

  @override
  KarplusStrongProcessor createProcessor() => KarplusStrongProcessor(
    frequency: frequency.valueOrNull,
    feedback: feedback.valueOrNull,
    pickHardness: pickHardness.valueOrNull,
    pickPosition: pickPosition.valueOrNull,
    damping: damping.valueOrNull,
    interpTime: interpTime,
  );

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: gateInlet, source: gate),
    Inlet(node: this, index: frequencyInlet, source: frequency.outletOrNull),
    Inlet(node: this, index: feedbackInlet, source: feedback.outletOrNull),
    Inlet(
      node: this,
      index: pickHardnessInlet,
      source: pickHardness.outletOrNull,
    ),
    Inlet(
      node: this,
      index: pickPositionInlet,
      source: pickPosition.outletOrNull,
    ),
    Inlet(node: this, index: dampingInlet, source: damping.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: outputOutlet)];

  Outlet get outlet => outlets.first;

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [
    frequency,
    feedback,
    pickHardness,
    pickPosition,
    damping,
    interpTime,
  ];

  @override
  KarplusStrongParams get params => (
    frequency: frequency.valueOrNull,
    feedback: feedback.valueOrNull,
    pickHardness: pickHardness.valueOrNull,
    pickPosition: pickPosition.valueOrNull,
    damping: damping.valueOrNull,
    interpTime: interpTime,
  );

  @override
  List<AudioNodeError> get errors => [
    if (interpTime < 0.0)
      const AudioNodeParamError(
        param: 'interpTime',
        error: 'must be non-negative',
      ),
  ];
}

class KarplusStrongProcessor({
  var double? frequency = 440.0,
  var double? feedback = 0.99,
  var double? pickHardness = 0.8,
  var double? pickPosition = 0.25,
  var double? damping = 0.5,
  var double interpTime = 0.02,
}) implements AudioProcessor {
  static const double _minFreq = 20.0;
  static const double _minLoopCutoff = 300.0;
  static const double _minPickCutoff = 200.0;
  static const double _maxPickGain = 4.0;
  static const double _muteDecayMaxRate = 35.0;

  int _sampleRate = 0;
  int _bufferMask = 0;
  Float32List? _buffer;
  Float32List? _excitationBuffer;
  int _bufferWriteIndex = 0;
  int _excWriteIndex = 0;

  double _lastFilterSample = 0.0;
  double _pickFilterState = 0.0;

  bool _lastGate = false;
  int _burstRemaining = 0;
  int _combTailRemaining = 0;

  int _rngState = 123456789;

  late final SmoothedValue _fbSmoother = SmoothedValue(
    (feedback ?? 0.99).fastClamp(0.0, 0.9999),
  );
  late final SmoothedValue _dampingSmoother = SmoothedValue(
    (damping ?? 0.5).fastClamp(0.0, 1.0),
  );

  void _ensureBuffers(int sampleRate) {
    if (_sampleRate == sampleRate && _buffer != null) return;
    _sampleRate = sampleRate;

    // Cover down to _minFreq with headroom for fractional interpolation.
    final needed = (sampleRate / _minFreq).ceil() + 8;
    int size = 1;
    while (size < needed) {
      size <<= 1;
    }
    _bufferMask = size - 1;
    _buffer = Float32List(size);
    _excitationBuffer = Float32List(size);
    _bufferWriteIndex = 0;
    _excWriteIndex = 0;
  }

  @override
  void update(Object params) {
    final p = params as KarplusStrongParams;
    final oldFb = feedback;
    final oldDamping = damping;

    frequency = p.frequency;
    feedback = p.feedback;
    pickHardness = p.pickHardness;
    pickPosition = p.pickPosition;
    damping = p.damping;
    interpTime = p.interpTime;

    if (p.feedback != null) {
      final clampedFb = p.feedback!.fastClamp(0.0, 0.9999);
      if (oldFb == null || interpTime <= 0.0) {
        _fbSmoother.snapTo(clampedFb);
      } else {
        _fbSmoother.setTarget(clampedFb);
      }
    }

    if (p.damping != null) {
      final clampedDamp = p.damping!.fastClamp(0.0, 1.0);
      if (oldDamping == null || interpTime <= 0.0) {
        _dampingSmoother.snapTo(clampedDamp);
      } else {
        _dampingSmoother.setTarget(clampedDamp);
      }
    }
  }

  /// Xorshift PRNG. See [NoiseGenerator].
  @pragma('vm:prefer-inline')
  double _nextNoise() {
    int x = _rngState;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= (x >> 17);
    x ^= (x << 5) & 0xFFFFFFFF;
    _rngState = x;
    return (x & 0x00FFFFFF) * (2.0 / 0x00FFFFFF) - 1.0;
  }

  @pragma('vm:prefer-inline')
  static double _loopDampingCoeff(double d, double sampleRate) {
    if (d <= 0.0) return 0.0;
    final maxCutoff = sampleRate * 0.45;
    final cutoff = maxCutoff * math.pow(_minLoopCutoff / maxCutoff, d * d);
    final g = math.exp(-2.0 * math.pi * cutoff / sampleRate);
    // Smoothly taper to exact 0.0 near d = 0 so there is no step discontinuity.
    return d < 0.05 ? g * (d * 20.0) : g;
  }

  /// Exact phase delay (in samples) of 1-pole lowpass H(z) = (1 - g) / (1 - g z^-1)
  /// at angular frequency omega0 = 2 * pi * freq / sampleRate.
  @pragma('vm:prefer-inline')
  static double _loopPhaseDelay(double g, double freq, double sampleRate) {
    if (g <= 0.0) return 0.0;
    final omega0 = (2.0 * math.pi * freq) / sampleRate;
    final phase = math.atan2(
      g * math.sin(omega0),
      1.0 - g * math.cos(omega0),
    );
    return phase / omega0;
  }

  @pragma('vm:prefer-inline')
  static double _muteDecayMultiplier(double d, double freq) {
    if (d <= 0.5) return 1.0;
    final mute = (d - 0.5) * 2.0;
    return math.exp(-(_muteDecayMaxRate * mute * mute) / freq);
  }

  @pragma('vm:prefer-inline')
  double _shapeExcitation(double raw, double hardness, double freq, double sr) {
    if (hardness >= 0.9999) return raw;
    final minCutoff = math.max(_minPickCutoff, freq * 1.2);
    final maxCutoff = sr * 0.45;
    final cutoff = maxCutoff <= minCutoff
        ? minCutoff
        : minCutoff * math.pow(maxCutoff / minCutoff, hardness);
    final a = math.exp(-2.0 * math.pi * cutoff / sr);
    _pickFilterState = (1.0 - a) * raw + a * _pickFilterState;
    final rmsGain = math.min(_maxPickGain, math.sqrt((1.0 + a) / (1.0 - a)));
    return _pickFilterState * rmsGain;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    _ensureBuffers(context.sampleRate);

    final buffer = _buffer!;
    final excBuffer = _excitationBuffer!;
    final mask = _bufferMask;
    final sampleRate = context.sampleRate.toDouble();
    final maxFreq = sampleRate * 0.45;
    final maxDelaySamples = (mask - 1).toDouble();

    final output = outputs[KarplusStrong.outputOutlet];
    final gateBuffer = inputs[KarplusStrong.gateInlet];
    final length = output.length;

    _fbSmoother.configure(sampleRate: sampleRate, rampTime: interpTime);
    _dampingSmoother.configure(sampleRate: sampleRate, rampTime: interpTime);

    final staticFreq = frequency;
    final staticFb = feedback;
    final staticHardness = pickHardness;
    final staticPos = pickPosition;
    final staticDamping = damping;

    final Float32List? freqBuf =
        staticFreq == null && inputs.length > KarplusStrong.frequencyInlet
        ? inputs[KarplusStrong.frequencyInlet]
        : null;
    final Float32List? fbBuf =
        staticFb == null && inputs.length > KarplusStrong.feedbackInlet
        ? inputs[KarplusStrong.feedbackInlet]
        : null;
    final Float32List? hardnessBuf =
        staticHardness == null &&
            inputs.length > KarplusStrong.pickHardnessInlet
        ? inputs[KarplusStrong.pickHardnessInlet]
        : null;
    final Float32List? posBuf =
        staticPos == null && inputs.length > KarplusStrong.pickPositionInlet
        ? inputs[KarplusStrong.pickPositionInlet]
        : null;
    final Float32List? dampingBuf =
        staticDamping == null && inputs.length > KarplusStrong.dampingInlet
        ? inputs[KarplusStrong.dampingInlet]
        : null;

    final isStaticFreq = freqBuf == null;
    final isStaticFb = fbBuf == null;
    final isStaticDamp = dampingBuf == null;
    final isFbSettled = _fbSmoother.isSettled;
    final isDampSettled = _dampingSmoother.isSettled;

    final double constFreq = (staticFreq ?? 440.0).fastClamp(_minFreq, maxFreq);
    final double constHardness = (staticHardness ?? 0.8).fastClamp(0.0, 1.0);
    final double constPos = (staticPos ?? 0.25).fastClamp(0.03, 0.97);

    // Precompute block constants when frequency, feedback, and damping are static and settled.
    final bool canUseBlockLoopParams =
        isStaticFreq &&
        isStaticFb &&
        isFbSettled &&
        isStaticDamp &&
        isDampSettled;
    final double blockDamp = _dampingSmoother.current.fastClamp(0.0, 1.0);
    final double blockG = canUseBlockLoopParams
        ? _loopDampingCoeff(blockDamp, sampleRate)
        : 0.0;
    final double blockDelaySamples = canUseBlockLoopParams
        ? ((sampleRate / constFreq) -
                  _loopPhaseDelay(blockG, constFreq, sampleRate))
              .fastClamp(1.0, maxDelaySamples)
        : 1.0;
    final double blockEffectiveFb = canUseBlockLoopParams
        ? (_fbSmoother.current.fastClamp(0.0, 0.9999) *
              _muteDecayMultiplier(blockDamp, constFreq))
        : 0.0;

    int writeIndex = _bufferWriteIndex;
    int excWriteIndex = _excWriteIndex;

    for (int i = 0; i < length; i++) {
      final bool isGateHigh = gateBuffer[i] > 0.0;
      final double freq = freqBuf != null
          ? freqBuf[i].fastClamp(_minFreq, maxFreq)
          : constFreq;

      if (isGateHigh && !_lastGate) {
        final periodSamples = (sampleRate / freq).round().clamp(1, mask);
        _burstRemaining = periodSamples;
        _combTailRemaining = periodSamples * 2 + 2;
        _pickFilterState = 0.0;
      }
      _lastGate = isGateHigh;

      double excitation = 0.0;
      if (_combTailRemaining > 0) {
        double shaped = 0.0;
        if (_burstRemaining > 0) {
          final hardness = hardnessBuf != null
              ? hardnessBuf[i].fastClamp(0.0, 1.0)
              : constHardness;
          shaped = _shapeExcitation(_nextNoise(), hardness, freq, sampleRate);
          _burstRemaining--;
        }

        final pos = posBuf != null
            ? posBuf[i].fastClamp(0.03, 0.97)
            : constPos;
        excBuffer[excWriteIndex] = shaped;

        final combDelay = (pos * (sampleRate / freq)).fastClamp(
          1.0,
          maxDelaySamples,
        );
        final int cInt = combDelay.floor();
        final double cFrac = combDelay - cInt;
        final int cRead0 = (excWriteIndex - cInt) & mask;
        final int cRead1 = (cRead0 - 1) & mask;
        final double delayedExc =
            excBuffer[cRead0] + cFrac * (excBuffer[cRead1] - excBuffer[cRead0]);

        excitation = 0.5 * (shaped - delayedExc);
        excWriteIndex = (excWriteIndex + 1) & mask;
        _combTailRemaining--;
      }

      final double g;
      final double delaySamples;
      final double effectiveFb;
      if (canUseBlockLoopParams) {
        g = blockG;
        delaySamples = blockDelaySamples;
        effectiveFb = blockEffectiveFb;
      } else {
        final double damp = dampingBuf != null
            ? dampingBuf[i].fastClamp(0.0, 1.0)
            : (isDampSettled ? _dampingSmoother.current : _dampingSmoother.next())
                  .fastClamp(0.0, 1.0);
        final double fb = fbBuf != null
            ? fbBuf[i].fastClamp(0.0, 0.9999)
            : (isFbSettled ? _fbSmoother.current : _fbSmoother.next())
                  .fastClamp(0.0, 0.9999);

        g = _loopDampingCoeff(damp, sampleRate);
        final phaseDelay = _loopPhaseDelay(g, freq, sampleRate);
        delaySamples = ((sampleRate / freq) - phaseDelay).fastClamp(
          1.0,
          maxDelaySamples,
        );
        effectiveFb = fb * _muteDecayMultiplier(damp, freq);
      }

      final int intPart = delaySamples.floor();
      final double frac = delaySamples - intPart;
      final int read0 = (writeIndex - intPart) & mask;
      final int read1 = (read0 - 1) & mask;
      final double delayedSample =
          buffer[read0] + frac * (buffer[read1] - buffer[read0]);

      final double lowpassed = (1.0 - g) * delayedSample + g * _lastFilterSample;
      _lastFilterSample = lowpassed.abs() < 1e-15 ? 0.0 : lowpassed;

      final double sample = excitation + lowpassed * effectiveFb;
      buffer[writeIndex] = sample;
      output[i] = sample;
      writeIndex = (writeIndex + 1) & mask;
    }

    _bufferWriteIndex = writeIndex;
    _excWriteIndex = excWriteIndex;
  }
}
