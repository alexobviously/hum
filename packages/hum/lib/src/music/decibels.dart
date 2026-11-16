import 'dart:math' as math;

/// Converts a decibel value [db] to linear amplitude gain factor.
///
/// Formula: `10 ^ (db / 20)`.
///
/// For example:
/// - `0.0 dB` -> `1.0`
/// - `-6.02 dB` -> `~0.5`
/// - `-12.0 dB` -> `~0.251`
/// - `+6.02 dB` -> `~2.0`
double dbToGain(num db) => math.pow(10.0, db / 20.0).toDouble();

/// Converts a linear amplitude gain factor [gain] to decibels.
///
/// Formula: `20 * log10(gain)`.
///
/// If [gain] is less than or equal to [floor], returns [minDb] (default -120.0 dB)
/// to prevent negative infinity.
double gainToDb(num gain, {double floor = 1e-6, double minDb = -120.0}) {
  if (gain <= floor) return minDb;
  return (20.0 * (math.log(gain) / math.ln10));
}

/// Fluent extension on numbers for decibel conversions.
extension DecibelNumExtension on num {
  /// Converts this number as decibels into linear amplitude gain.
  ///
  /// Example: `-6.db` or `3.db`.
  double get db => dbToGain(this);

  /// Converts this number as a linear amplitude gain factor into decibels.
  ///
  /// Example: `0.5.toDb` -> `-6.02 dB`.
  double get toDb => gainToDb(this);
}
