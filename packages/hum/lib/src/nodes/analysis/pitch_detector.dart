import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Parameter bag for updating a [PitchDetectorProcessor] in-place.
typedef PitchDetectorParams = ({double? threshold, double? minRms});

/// Pitch-detection telemetry reading emitted by [PitchDetector].
class const PitchReading({
  /// Detected fundamental frequency in Hz (`0.0` when unpitched or silent).
  required final double frequency,

  /// YIN pitch confidence in `[0.0, 1.0]` (`1.0 - cmndf[bestLag]`, or `0.0`
  /// when gated by silence).
  required final double clarity,

  /// Reference A4 tuning in Hz used for [midi], [note], and [cents].
  final double a4 = 440.0,
}) {
  /// Whether a valid pitch was detected (`frequency > 0.0`).
  bool get hasPitch => frequency > 0.0;

  /// Fractional 12-TET MIDI note number, or `null` when unpitched.
  double? get midi => hasPitch ? hzToMidi(frequency, a4) : null;

  /// Nearest 12-TET [Note], or `null` when unpitched.
  Note? get note => hasPitch ? Note.hz(frequency, a4) : null;

  /// Deviation from the nearest 12-TET [note] in cents (`[-50.0, +50.0]`),
  /// or `null` when unpitched.
  double? get cents {
    if (!hasPitch) return null;
    final double m = hzToMidi(frequency, a4);
    return (m - m.round()) * 100.0;
  }

  @override
  String toString() {
    if (!hasPitch) {
      return 'PitchReading(unpitched, clarity: ${clarity.toStringAsFixed(3)})';
    }

    final c = cents!;
    final sign = c >= 0 ? '+' : '';

    return 'PitchReading(${note!.name} $sign${c.toStringAsFixed(1)}c, '
        '${frequency.toStringAsFixed(2)} Hz, '
        'clarity: ${clarity.toStringAsFixed(3)})';
  }
}

/// A monophonic YIN pitch detector node with dual-domain outputs:
///
/// - **Audio-rate outlets:** [audio] passthrough, [frequency] CV (Hz, holds
///   last valid pitch when unpitched), [gate] CV (`1.0` pitched / `0.0`
///   unpitched), and [clarity] CV (`0.0..1.0` pitch confidence).
/// - **Host telemetry:** throttled [PitchReading] snapshots via
///   [TelemetryNode] (`frequency`, `clarity`, `note`, `midi`, `cents`).
///
/// Implements the YIN algorithm (de Cheveigné & Kawahara, 2002):
/// 1. Squared difference function $d(\tau)$
/// 2. Cumulative mean normalized difference $d'(\tau)$
/// 3. Absolute threshold search for octave-error rejection
/// 4. Parabolic interpolation for sub-cent frequency accuracy
class PitchDetector({
  /// Input audio signal to track.
  required final Outlet input,

  /// Integration window length in samples for the YIN difference function.
  final int windowSize = 1024,

  /// Hop interval in samples between successive pitch analyses.
  final int hopSize = 256,

  /// Lowest detectable fundamental frequency in Hz.
  final double minFrequency = 50.0,

  /// Highest detectable fundamental frequency in Hz.
  final double maxFrequency = 1000.0,

  /// YIN absolute threshold on the cumulative mean normalized difference
  /// function (typical range `0.10`–`0.20`; lower is stricter).
  final double threshold = 0.15,

  /// Minimum linear RMS amplitude required to attempt pitch detection.
  /// Signals below this level are treated as unpitched (`gate = 0.0`).
  /// Use `(-46).db` if you prefer specifying the gate in dBFS.
  final double minRms = 0.005,

  /// Reference A4 tuning in Hz for [PitchReading.note] and [PitchReading.cents].
  final double a4 = 440.0,
}) extends AudioNode<PitchDetectorProcessor> with TelemetryNode<PitchReading> {
  @override
  List<Inlet> get inlets => [Inlet(node: this, index: 0, source: input)];

  @override
  late final List<Outlet> outlets = [
    Outlet(node: this, index: 0),
    Outlet(node: this, index: 1),
    Outlet(node: this, index: 2),
    Outlet(node: this, index: 3),
  ];

  /// Audio passthrough outlet.
  Outlet get audio => outlets[0];

  /// Audio-rate frequency CV outlet in Hz. Holds the last detected frequency
  /// while unpitched so downstream oscillators release cleanly with [gate].
  Outlet get frequency => outlets[1];

  /// Audio-rate gate CV outlet (`1.0` when pitched, `0.0` when unpitched).
  Outlet get gate => outlets[2];

  /// Audio-rate pitch confidence CV outlet in `[0.0, 1.0]`.
  Outlet get clarity => outlets[3];

  @override
  PitchDetectorProcessor createProcessor() => PitchDetectorProcessor(
    windowSize: windowSize,
    hopSize: hopSize,
    minFrequency: minFrequency,
    maxFrequency: maxFrequency,
    threshold: threshold,
    minRms: minRms,
  );

  @override
  List<AudioNodeError> get errors => [
    if (windowSize <= 0)
      const AudioNodeParamError(param: 'windowSize', error: 'must be positive'),
    if (hopSize <= 0)
      const AudioNodeParamError(param: 'hopSize', error: 'must be positive'),
    if (minFrequency <= 0.0)
      const AudioNodeParamError(
        param: 'minFrequency',
        error: 'must be positive',
      ),
    if (maxFrequency <= minFrequency)
      const AudioNodeParamError(
        param: 'maxFrequency',
        error: 'must be greater than minFrequency',
      ),
    if (threshold <= 0.0 || threshold >= 1.0)
      const AudioNodeParamError(
        param: 'threshold',
        error: 'must be in (0.0, 1.0)',
      ),
    if (minRms < 0.0)
      const AudioNodeParamError(param: 'minRms', error: 'must be non-negative'),
    if (a4 <= 0.0)
      const AudioNodeParamError(param: 'a4', error: 'must be positive'),
  ];

  @override
  List<Object?> get fixedProps => [
    windowSize,
    hopSize,
    minFrequency,
    maxFrequency,
  ];

  @override
  List<Object?> get dynamicProps => [threshold, minRms];

  @override
  Object get params => (threshold: threshold, minRms: minRms);

  @override
  PitchReading decodeTelemetry(Float32List data) =>
      PitchReading(frequency: data[0], clarity: data[1], a4: a4);
}

/// Runtime processor for [PitchDetector].
class PitchDetectorProcessor({
  final int windowSize = 1024,
  final int hopSize = 256,
  final double minFrequency = 50.0,
  final double maxFrequency = 1000.0,
  double threshold = 0.15,
  double minRms = 0.005,
}) implements TelemetryProcessor {
  double _threshold = threshold;
  double _minRms = minRms;

  int _allocatedSampleRate = 0;
  int _minTau = 1;
  int _maxTau = 2;
  int _lagLimit = 3;
  Float32List _ring = Float32List(0);
  Float32List _linear = Float32List(0);
  Float32List _cmndf = Float32List(0);

  int _writeIdx = 0;
  int _samplesReceived = 0;
  int _hopCount = 0;

  double _detectedFrequency = 0.0;
  double _heldFrequency = 0.0;
  double _gate = 0.0;
  double _clarity = 0.0;
  bool _hasNewReading = false;

  /// Most recently detected fundamental frequency in Hz (`0.0` when unpitched).
  double get frequency => _detectedFrequency;

  /// Last valid detected frequency in Hz (held across unpitched segments).
  double get heldFrequency => _heldFrequency;

  /// Current pitch clarity / confidence in `[0.0, 1.0]`.
  double get clarity => _clarity;

  /// Whether the most recent analysis detected a valid pitch.
  bool get isPitched => _gate > 0.5;

  @override
  int get telemetryLength => 2;

  @override
  void update(Object params) {
    if (params case final PitchDetectorParams p) {
      if (p.threshold != null) _threshold = p.threshold!;
      if (p.minRms != null) _minRms = p.minRms!;
    }
  }

  void _ensureAllocated(int sampleRate) {
    if (_allocatedSampleRate == sampleRate) return;
    _allocatedSampleRate = sampleRate;
    _maxTau = math.max(2, (sampleRate / minFrequency).ceil());
    _minTau = math.max(1, (sampleRate / maxFrequency).floor());
    if (_minTau >= _maxTau) {
      _minTau = _maxTau - 1;
    }
    // Allocate one extra lag slot so parabolic interpolation at `_maxTau`
    // always has a valid right neighbor (`_maxTau + 1`).
    _lagLimit = _maxTau + 1;
    final int totalLen = windowSize + _lagLimit;
    _ring = Float32List(totalLen);
    _linear = Float32List(totalLen);
    _cmndf = Float32List(_lagLimit + 1);
    _writeIdx = 0;
    _samplesReceived = 0;
    _hopCount = 0;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    _ensureAllocated(context.sampleRate);

    final input = inputs[0];
    final int vectorSize = context.vectorSize;

    // 0: Audio passthrough.
    if (outputs.isNotEmpty) {
      outputs[0].setRange(0, vectorSize, input);
    }

    // Push incoming samples into the ring buffer.
    final int ringLen = _ring.length;
    for (int i = 0; i < vectorSize; i++) {
      _ring[_writeIdx] = input[i];
      _writeIdx++;
      if (_writeIdx == ringLen) _writeIdx = 0;
    }
    if (_samplesReceived < ringLen) {
      _samplesReceived += vectorSize;
    }

    // Trigger YIN analysis on hop boundaries once the buffer is full.
    _hopCount += vectorSize;
    if (_hopCount >= hopSize) {
      _hopCount %= hopSize;
      if (_samplesReceived >= ringLen) {
        _analyze(context.sampleRate);
      }
    }

    // 1: Frequency CV (holds last valid pitch).
    if (outputs.length > 1) {
      outputs[1].fillRange(0, vectorSize, _heldFrequency);
    }
    // 2: Gate CV (1.0 pitched, 0.0 unpitched).
    if (outputs.length > 2) {
      outputs[2].fillRange(0, vectorSize, _gate);
    }
    // 3: Clarity CV (0.0..1.0).
    if (outputs.length > 3) {
      outputs[3].fillRange(0, vectorSize, _clarity);
    }
  }

  void _reportUnpitched(double clarity) {
    _detectedFrequency = 0.0;
    _gate = 0.0;
    _clarity = clarity;
    _hasNewReading = true;
  }

  void _analyze(int sampleRate) {
    final int ringLen = _ring.length;

    // Unroll ring buffer into contiguous linear buffer (oldest sample first).
    final int tailLen = ringLen - _writeIdx;
    _linear.setRange(0, tailLen, _ring, _writeIdx);
    if (_writeIdx > 0) {
      _linear.setRange(tailLen, ringLen, _ring, 0);
    }

    // Silence / noise floor gate via window RMS.
    double sumSq = 0.0;
    for (int j = 0; j < windowSize; j++) {
      final double s = _linear[j];
      sumSq += s * s;
    }
    if (sumSq == 0.0) {
      _reportUnpitched(0.0);
      return;
    }
    final double rms = math.sqrt(sumSq / windowSize);
    if (rms < _minRms) {
      _reportUnpitched(0.0);
      return;
    }

    // Steps 1 & 2: Squared difference function d(tau) and cumulative mean
    // normalized difference function d'(tau).
    _cmndf[0] = 1.0;
    double runningSum = 0.0;
    for (int tau = 1; tau <= _lagLimit; tau++) {
      double diff = 0.0;
      for (int j = 0; j < windowSize; j++) {
        final double delta = _linear[j] - _linear[j + tau];
        diff += delta * delta;
      }
      runningSum += diff;
      _cmndf[tau] = runningSum > 0.0 ? (diff * tau) / runningSum : 1.0;
    }

    // Step 3: Absolute threshold — first local minimum below `_threshold`.
    int bestTau = -1;
    for (int tau = _minTau; tau <= _maxTau; tau++) {
      if (_cmndf[tau] < _threshold) {
        while (tau + 1 <= _maxTau && _cmndf[tau + 1] < _cmndf[tau]) {
          tau++;
        }
        bestTau = tau;
        break;
      }
    }

    if (bestTau < 0) {
      // Unpitched: still compute honest low clarity from the best candidate.
      double minVal = 1.0;
      for (int tau = _minTau; tau <= _maxTau; tau++) {
        if (_cmndf[tau] < minVal) minVal = _cmndf[tau];
      }
      _reportUnpitched((1.0 - minVal).clamp(0.0, 1.0));
      return;
    }

    // Step 4: Parabolic interpolation around `bestTau` for sub-sample accuracy.
    final double s0 = _cmndf[bestTau - 1];
    final double s1 = _cmndf[bestTau];
    final double s2 = _cmndf[bestTau + 1];
    final double denom = 2.0 * (s0 - 2.0 * s1 + s2);
    double refinedTau = bestTau.toDouble();
    if (denom.abs() > 1e-12) {
      final double shift = (s0 - s2) / denom;
      if (shift.abs() <= 1.0) {
        refinedTau += shift;
      }
    }

    final double hz = refinedTau > 0.0 ? sampleRate / refinedTau : 0.0;
    _detectedFrequency = hz;
    _heldFrequency = hz;
    _gate = 1.0;
    _clarity = (1.0 - s1).clamp(0.0, 1.0);
    _hasNewReading = true;
  }

  @override
  bool writeTelemetry(Float32List out, int offset) {
    if (!_hasNewReading) return false;
    out[offset] = _detectedFrequency;
    out[offset + 1] = _clarity;
    _hasNewReading = false;
    return true;
  }
}

/// Convenience extension for attaching a [PitchDetector] to an [Outlet].
extension PitchDetectorExtension on Outlet {
  /// Inserts a YIN [PitchDetector] on this outlet.
  PitchDetector pitchDetector({
    int windowSize = 1024,
    int hopSize = 256,
    double minFrequency = 50.0,
    double maxFrequency = 1000.0,
    double threshold = 0.15,
    double minRms = 0.005,
    double a4 = 440.0,
  }) => PitchDetector(
    input: this,
    windowSize: windowSize,
    hopSize: hopSize,
    minFrequency: minFrequency,
    maxFrequency: maxFrequency,
    threshold: threshold,
    minRms: minRms,
    a4: a4,
  );
}
