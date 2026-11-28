import 'package:hum/hum.dart';

/// A synthesised snare drum: a short, pitch-swept sine "body" mixed with a
/// highpassed noise "snap", each with its own decay envelope.
///
/// ```text
/// trigger ─┬─ Decay(pitchDecay) ─ Mult(sweep) ─ Add(frequency) ─ SineOscillator ─ Mult(bodyEnv) ─ Mult(bodyLevel) ─┐
///          ├─ Decay(noiseDecay) ───────────────────────────┐                                                       Sum ─ Mult(velocity)
///          │  NoiseGenerator ─ SvfFilter(highpass) ─ Mult(noiseEnv) ─ Mult(noiseLevel) ────────────────────────────┘
///          └─ Sah (velocity)
/// ```
///
/// This is a composite: it just wires up regular nodes and holds on to them,
/// so the compiler sees (and optimises) the expanded graph. Use [outlet] to
/// connect it to the rest of your graph.
///
/// The [trigger] doubles as velocity. Any positive value fires the snare, and
/// the value at the moment of the trigger scales the amplitude (a trigger of
/// `1.0` is full velocity, `0.5` is half) until the next hit.
///
/// - [frequency] is the resting pitch of the body, in hertz.
/// - [sweep] is how many hertz above [frequency] the body pitch starts at.
/// - [pitchDecay] is how long, in seconds, the body pitch takes to fall.
/// - [bodyDecay] and [noiseDecay] are the amplitude decay times, in seconds.
/// - [noiseCutoff] is the highpass cutoff of the noise, in hertz.
/// - [bodyLevel] and [noiseLevel] set the balance between the two layers.
/// - [seed] seeds the noise generator for repeatable output.
class Snare {
  final Sah velocity;
  final Decay pitchEnv;
  final Mult pitchSweep;
  final Add pitch;
  final SineOscillator osc;
  final Decay bodyEnv;
  final Mult bodyAmp;
  final Mult body;
  final NoiseGenerator noiseSource;
  final SvfFilter noiseFilter;
  final Decay noiseEnv;
  final Mult noiseAmp;
  final Mult noise;
  final Sum mix;
  final Mult velocityAmp;

  Snare._({
    required this.velocity,
    required this.pitchEnv,
    required this.pitchSweep,
    required this.pitch,
    required this.osc,
    required this.bodyEnv,
    required this.bodyAmp,
    required this.body,
    required this.noiseSource,
    required this.noiseFilter,
    required this.noiseEnv,
    required this.noiseAmp,
    required this.noise,
    required this.mix,
    required this.velocityAmp,
  });

  Outlet get outlet => velocityAmp.outlet;

  factory Snare({
    required Outlet trigger,
    ControlParam<double> frequency = const .value(190.0),
    ControlParam<double> sweep = const .value(70.0),
    ControlParam<double> pitchDecay = const .value(0.03),
    ControlParam<double> bodyDecay = const .value(0.1),
    ControlParam<double> noiseDecay = const .value(0.18),
    ControlParam<double> noiseCutoff = const .value(1800.0),
    ControlParam<double> bodyLevel = const .value(0.6),
    ControlParam<double> noiseLevel = const .value(0.8),
    int? seed,
  }) {
    // Threshold of 0 so that quiet triggers (velocity < 0.5) still register.
    final velocity = Sah.mono(trigger: trigger, input: trigger, threshold: 0.0);

    // Body
    final pitchEnv = Decay.pure(trigger: trigger, time: pitchDecay);
    final pitchSweep = Mult.mono(input: pitchEnv.outlet, value: sweep);
    final pitch = Add.mono(input: pitchSweep.outlet, value: frequency);
    final osc = SineOscillator(frequency: .signal(pitch.outlet));
    final bodyEnv = Decay.pure(trigger: trigger, time: bodyDecay);
    final bodyAmp = Mult.mono(
      input: osc.outlet,
      value: .signal(bodyEnv.outlet),
    );
    final body = Mult.mono(input: bodyAmp.outlet, value: bodyLevel);

    // Noise
    final noiseSource = NoiseGenerator.white(seed: seed);
    final noiseFilter = SvfFilter(
      input: noiseSource.outlet,
      cutoff: noiseCutoff,
    );
    final noiseEnv = Decay.pure(trigger: trigger, time: noiseDecay);
    final noiseAmp = Mult.mono(
      input: noiseFilter.highpass,
      value: .signal(noiseEnv.outlet),
    );
    final noise = Mult.mono(input: noiseAmp.outlet, value: noiseLevel);

    final mix = Sum.pair(body.outlet, noise.outlet);
    final velocityAmp = Mult.mono(
      input: mix.outlet,
      value: .signal(velocity.outlet),
    );

    return Snare._(
      velocity: velocity,
      pitchEnv: pitchEnv,
      pitchSweep: pitchSweep,
      pitch: pitch,
      osc: osc,
      bodyEnv: bodyEnv,
      bodyAmp: bodyAmp,
      body: body,
      noiseSource: noiseSource,
      noiseFilter: noiseFilter,
      noiseEnv: noiseEnv,
      noiseAmp: noiseAmp,
      noise: noise,
      mix: mix,
      velocityAmp: velocityAmp,
    );
  }
}
