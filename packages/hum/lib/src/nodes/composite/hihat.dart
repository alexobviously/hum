import 'package:hum/hum.dart';

/// A synthesised hi-hat supporting both a classic filtered-noise topology
/// ([HiHat.noise]) and the metallic 6-oscillator TR-808 topology
/// ([HiHat.metallic]).
///
/// ```text
/// (noise)     NoiseGenerator ───────────────────────────────────┐
/// (metallic)  6× SquareOscillator ─ Sum ─ SvfFilter(bandpass) ──┼─ SvfFilter(highpass) ─ Mult(env) ─ Mult(velocity)
///                                                               │
/// trigger ─┬─ Decay(decay) ─────────────────────────────────────┘
///          └─ Sah (velocity)
/// ```
///
/// Closed vs. open hats are determined by [decay] (e.g. `0.04`s for a tight
/// closed hat, `0.25`–`0.45`s for an open hat); [decay] is a [ControlParam] so
/// a single instance can switch between closed and open per step by modulating
/// `decay` with a signal.
///
/// The [trigger] doubles as velocity. Any positive value fires the hat, and
/// the value at the moment of the trigger scales the amplitude until the next
/// hit.
class HiHat {
  final Sah velocity;

  /// Present on [HiHat.noise] instances.
  final NoiseGenerator? noiseSource;

  /// The 6 inharmonic square oscillators on [HiHat.metallic] instances.
  final List<SquareOscillator>? metalOscs;

  /// Sums [metalOscs] on [HiHat.metallic] instances.
  final Sum? metalSum;

  /// Bandpass stage shaping the metallic cluster on [HiHat.metallic] instances.
  final SvfFilter? bandpassFilter;

  final SvfFilter highpassFilter;
  final Decay ampEnv;
  final Mult amp;
  final Mult velocityAmp;

  HiHat._({
    required this.velocity,
    this.noiseSource,
    this.metalOscs,
    this.metalSum,
    this.bandpassFilter,
    required this.highpassFilter,
    required this.ampEnv,
    required this.amp,
    required this.velocityAmp,
  });

  Outlet get outlet => velocityAmp.outlet;

  /// Default constructor creates the classic filtered-noise hi-hat.
  factory HiHat({
    required Outlet trigger,
    ControlParam<double> decay,
    ControlParam<double> cutoff,
    ControlParam<double> resonance,
    int? seed,
  }) = HiHat.noise;

  /// Crisp white-noise hi-hat passed through a highpass [SvfFilter].
  ///
  /// - [decay] is the amplitude decay time in seconds (`~0.04` closed, `~0.3` open).
  /// - [cutoff] is the highpass cutoff in hertz.
  /// - [resonance] adds a slight metallic ring around the cutoff.
  /// - [seed] seeds the noise generator for repeatable output.
  factory HiHat.noise({
    required Outlet trigger,
    ControlParam<double> decay = const .value(0.045),
    ControlParam<double> cutoff = const .value(7500.0),
    ControlParam<double> resonance = const .value(0.9),
    int? seed,
  }) {
    final velocity = Sah.mono(trigger: trigger, input: trigger, threshold: 0.0);
    final noiseSource = NoiseGenerator.white(seed: seed);
    final highpassFilter = SvfFilter(
      input: noiseSource.outlet,
      cutoff: cutoff,
      resonance: resonance,
    );
    final ampEnv = Decay.pure(trigger: trigger, time: decay);
    final amp = Mult.mono(
      input: highpassFilter.highpass,
      value: .signal(ampEnv.outlet),
    );
    final velocityAmp = Mult.mono(
      input: amp.outlet,
      value: .signal(velocity.outlet),
    );

    return HiHat._(
      velocity: velocity,
      noiseSource: noiseSource,
      highpassFilter: highpassFilter,
      ampEnv: ampEnv,
      amp: amp,
      velocityAmp: velocityAmp,
    );
  }

  /// Classic TR-808 style metallic hi-hat built from 6 inharmonically tuned
  /// square-wave oscillators summed into a bandpass + highpass filter pair.
  ///
  /// - [decay] is the amplitude decay time in seconds (`~0.045` closed, `~0.35` open).
  /// - [tune] scales all 6 oscillator frequencies (`1.0` = classic 808 ratios).
  /// - [bandpassCutoff] and [bandpassResonance] shape the midrange metallic body.
  /// - [highpassCutoff] strips the low fundamentals leaving the shimmer.
  factory HiHat.metallic({
    required Outlet trigger,
    ControlParam<double> decay = const .value(0.05),
    double tune = 1.0,
    ControlParam<double> bandpassCutoff = const .value(3600.0),
    ControlParam<double> bandpassResonance = const .value(1.4),
    ControlParam<double> highpassCutoff = const .value(7200.0),
  }) {
    // Classic 808-style inharmonic square-wave cluster (Hz).
    const baseFreqs = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0];

    final velocity = Sah.mono(trigger: trigger, input: trigger, threshold: 0.0);
    final metalOscs = [
      for (final f in baseFreqs) SquareOscillator(frequency: .value(f * tune)),
    ];
    final metalSum = Sum(inputs: [for (final o in metalOscs) o.outlet]);

    final bandpassFilter = SvfFilter(
      input: metalSum.outlet,
      cutoff: bandpassCutoff,
      resonance: bandpassResonance,
    );
    final highpassFilter = SvfFilter(
      input: bandpassFilter.bandpass,
      cutoff: highpassCutoff,
      resonance: const .value(0.8),
    );

    final ampEnv = Decay.pure(trigger: trigger, time: decay);
    final amp = Mult.mono(
      input: highpassFilter.highpass,
      value: .signal(ampEnv.outlet),
    );
    final velocityAmp = Mult.mono(
      input: amp.outlet,
      value: .signal(velocity.outlet),
    );

    return HiHat._(
      velocity: velocity,
      metalOscs: metalOscs,
      metalSum: metalSum,
      bandpassFilter: bandpassFilter,
      highpassFilter: highpassFilter,
      ampEnv: ampEnv,
      amp: amp,
      velocityAmp: velocityAmp,
    );
  }
}
