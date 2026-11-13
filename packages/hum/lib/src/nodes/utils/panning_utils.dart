import 'dart:math' as math;

import 'clamp.dart';

/// Returns equal-power (quarter-sine/cosine) left gain for a bipolar position in `[-1.0, +1.0]`.
@pragma('vm:prefer-inline')
double equalPowerGainLeft(double position) {
  if (position <= -1.0) return 1.0;
  if (position >= 1.0) return 0.0;
  return math.cos((position + 1.0) * (math.pi / 4));
}

/// Returns equal-power (quarter-sine/cosine) right gain for a bipolar position in `[-1.0, +1.0]`.
@pragma('vm:prefer-inline')
double equalPowerGainRight(double position) {
  if (position <= -1.0) return 0.0;
  if (position >= 1.0) return 1.0;
  return math.sin((position + 1.0) * (math.pi / 4));
}

/// Returns equal-power (quarter-sine/cosine) gains for a bipolar position in `[-1.0, +1.0]`.
///
/// * At `-1.0` (hard left / 100% A), returns `(1.0, 0.0)`.
/// * At `0.0` (centre / 50-50 mix), returns `(sqrt(0.5), sqrt(0.5))` (~`0.7071`, +0 dB acoustic sum).
/// * At `+1.0` (hard right / 100% B), returns `(0.0, 1.0)`.
(double left, double right) equalPowerGains(double position) =>
    (equalPowerGainLeft(position), equalPowerGainRight(position));

/// Returns linear left gain for a bipolar position in `[-1.0, +1.0]`.
@pragma('vm:prefer-inline')
double linearGainLeft(double position) {
  final norm = (position.fastClamp(-1.0, 1.0) + 1.0) * 0.5;
  return 1.0 - norm;
}

/// Returns linear right gain for a bipolar position in `[-1.0, +1.0]`.
@pragma('vm:prefer-inline')
double linearGainRight(double position) {
  final norm = (position.fastClamp(-1.0, 1.0) + 1.0) * 0.5;
  return norm;
}

/// Returns linear gains for a bipolar position in `[-1.0, +1.0]`.
///
/// * At `-1.0` (hard left / 100% A), returns `(1.0, 0.0)`.
/// * At `0.0` (centre / 50-50 mix), returns `(0.5, 0.5)`.
/// * At `+1.0` (hard right / 100% B), returns `(0.0, 1.0)`.
(double left, double right) linearGains(double position) =>
    (linearGainLeft(position), linearGainRight(position));

/// Returns the dry gain for an equal-power unipolar mix in `[0.0, 1.0]`.
@pragma('vm:prefer-inline')
double equalPowerDry(double mix) {
  if (mix <= 0.0) return 1.0;
  if (mix >= 1.0) return 0.0;
  return math.cos(mix * (math.pi / 2));
}

/// Returns the wet gain for an equal-power unipolar mix in `[0.0, 1.0]`.
@pragma('vm:prefer-inline')
double equalPowerWet(double mix) {
  if (mix <= 0.0) return 0.0;
  if (mix >= 1.0) return 1.0;
  return math.sin(mix * (math.pi / 2));
}

/// Returns equal-power gains for a unipolar dry/wet mix in `[0.0, 1.0]`.
///
/// * At `0.0` (100% dry), returns `(1.0, 0.0)`.
/// * At `0.5` (50-50 blend), returns `(sqrt(0.5), sqrt(0.5))` (~`0.7071`, +0 dB acoustic sum).
/// * At `1.0` (100% wet), returns `(0.0, 1.0)`.
(double dry, double wet) equalPowerMix(double mix) =>
    (equalPowerDry(mix), equalPowerWet(mix));

/// Returns linear gains for a unipolar dry/wet mix in `[0.0, 1.0]`.
///
/// * At `0.0` (100% dry), returns `(1.0, 0.0)`.
/// * At `0.5` (50-50 blend), returns `(0.5, 0.5)`.
/// * At `1.0` (100% wet), returns `(0.0, 1.0)`.
(double dry, double wet) linearMix(double mix) {
  final clamped = mix.fastClamp(0.0, 1.0);
  return (1.0 - clamped, clamped);
}
