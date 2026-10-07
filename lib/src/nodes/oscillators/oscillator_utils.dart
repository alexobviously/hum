/// Wraps the phase to the range 0.0 - 1.0.
double wrapPhase(double phase) {
  phase %= 1.0;
  if (phase < 0.0) phase += 1.0;
  return phase;
}

/// Basically just exists to avoid modulo operations in the hot path.
@pragma('vm:prefer-inline')
double advancePhase(double phase, double increment) {
  final nextPhase = phase + increment;

  return switch (nextPhase) {
    >= 1.0 && < 2.0 => nextPhase - 1.0,
    >= 1.0 => wrapPhase(nextPhase),
    < 0.0 && >= -1.0 => nextPhase + 1.0,
    < 0.0 => wrapPhase(nextPhase),
    _ => nextPhase,
  };
}

/// For antialiasing square and sawtooth waves.
/// https://www.martin-finke.de/articles/audio-plugins-018-polyblep-oscillator/
@pragma('vm:prefer-inline')
double polyBlep(double phase, double dt) {
  if (dt <= 0.0 || dt > 0.5) return 0.0;

  if (phase < dt) {
    final t = phase / dt;
    return t + t - t * t - 1.0;
  }

  if (phase > 1.0 - dt) {
    final t = (phase - 1.0) / dt;
    return t * t + t + t + 1.0;
  }

  return 0.0;
}
