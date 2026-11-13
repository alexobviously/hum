import 'dart:math' as math;

// TODO: this works, but the code you have to write to use it is more verbose than I'd like

/// A lightweight, allocation-free parameter smoother (1-pole lowpass filter).
///
/// Designed to eliminate zipper noise, clicks, and discontinuities when static
/// control parameters are updated at block boundaries.
///
/// Features an inline fast-path when the value has settled (`_current == _target`),
/// bypassing all computation during steady-state processing.
class SmoothedValue {
  double _current;
  double _target;
  double _coeff = 1.0;
  double _sampleRate = 44100.0;
  double _rampTime = 0.05;

  // Settle factor ln(1000) ≈ 6.907755 so that the smoother reaches 99.9% (-60 dB)
  // of the target within the specified rampTime.
  static const double _settleFactor = 6.907755278982137;
  static const double _settleThreshold = 1e-5;

  SmoothedValue([double initialValue = 0.0])
    : _current = initialValue,
      _target = initialValue;

  /// Current interpolated value.
  @pragma('vm:prefer-inline')
  double get current => _current;

  /// Target value being glided towards.
  @pragma('vm:prefer-inline')
  double get target => _target;

  /// Whether the smoother has completed its glide to the target value.
  @pragma('vm:prefer-inline')
  bool get isSettled => _current == _target;

  /// Configures the sample rate and ramp time (in seconds).
  @pragma('vm:prefer-inline')
  void configure({required double sampleRate, required double rampTime}) {
    if (_sampleRate == sampleRate && _rampTime == rampTime) return;
    _sampleRate = sampleRate;
    _rampTime = rampTime;
    if (rampTime <= 0.0 || sampleRate <= 0.0) {
      _coeff = 1.0;
    } else {
      _coeff = 1.0 - math.exp(-_settleFactor / (sampleRate * rampTime));
    }
  }

  /// Sets a new [target] value to glide towards.
  void setTarget(double target) {
    _target = target;
  }

  /// Instantly teleports [current] and [target] to [value] with zero glide.
  void snapTo(double value) {
    _current = value;
    _target = value;
  }

  /// Advances the smoother by one sample and returns the current interpolated value.
  @pragma('vm:prefer-inline')
  double next() {
    if (_current == _target) return _current;
    _current += _coeff * (_target - _current);
    if ((_target - _current).abs() < _settleThreshold) {
      _current = _target;
    }
    return _current;
  }

  /// Skips smoothing ahead by [samples] frames.
  void skip(int samples) {
    if (_current == _target || samples <= 0) return;
    final decay = math.pow(1.0 - _coeff, samples).toDouble();
    _current = _target - (_target - _current) * decay;
    if ((_target - _current).abs() < _settleThreshold) {
      _current = _target;
    }
  }
}
