/// The curvature shape used by envelope generators ([Adsr], [Decay]).
enum EnvelopeCurve {
  /// Pure linear ramps between stages.
  linear,

  /// Punchy exponential charge for attack and natural exponential discharge
  /// for decay and release, mimicking classic analog RC synthesizer circuits.
  exponential,
}
