import 'package:hum/hum.dart';

/// A synthesised kick drum: a sine oscillator whose pitch falls quickly from
/// `frequency + sweep` down to `frequency`, shaped by an amplitude decay and
/// (optionally) saturated.
///
/// ```text
/// trigger ─┬─ Decay(pitchDecay) ─ Mult(sweep) ─ Add(freq) ─ SineOscillator ─┐
///          ├─ Decay(decay) ─────────────────────────────────────────────── Mult
///          └─ Sah (velocity) ───────────────────────────────────────────── Mult ─ (Saturator)
/// ```
///
/// This is a composite: it just wires up regular nodes and holds on to them,
/// so the compiler sees (and optimises) the expanded graph. Use [outlet] to
/// connect it to the rest of your graph.
///
/// The [trigger] doubles as velocity. Any positive value fires the kick, and
/// the value at the moment of the trigger scales the amplitude (a trigger of
/// `1.0` is full velocity, `0.5` is half) until the next hit.
///
/// - [frequency] is the resting pitch of the body, in hertz.
/// - [sweep] is how many hertz above [frequency] the pitch starts at.
/// - [pitchDecay] is how long, in seconds, the pitch takes to fall.
/// - [decay] is the amplitude decay time, in seconds.
/// - [drive] adds a [Saturator] with this drive after the velocity scaling, so
///   harder hits are also more saturated. `null` (the default) omits it.
class Kick {
  final Sah velocity;
  final Decay pitchEnv;
  final Mult pitchSweep;
  final Add pitch;
  final SineOscillator osc;
  final Decay ampEnv;
  final Mult amp;
  final Mult velocityAmp;
  final Saturator? saturator;

  Kick._({
    required this.velocity,
    required this.pitchEnv,
    required this.pitchSweep,
    required this.pitch,
    required this.osc,
    required this.ampEnv,
    required this.amp,
    required this.velocityAmp,
    this.saturator,
  });

  Outlet get outlet => saturator?.outlet ?? velocityAmp.outlet;

  factory Kick({
    required Outlet trigger,
    ControlParam<double> frequency = const .value(45.0),
    ControlParam<double> sweep = const .value(120.0),
    ControlParam<double> pitchDecay = const .value(0.045),
    ControlParam<double> decay = const .value(0.22),
    ControlParam<double>? drive,
  }) {
    // Threshold of 0 so that quiet triggers (velocity < 0.5) still register.
    final velocity = Sah.mono(trigger: trigger, input: trigger, threshold: 0.0);

    final pitchEnv = Decay.pure(trigger: trigger, time: pitchDecay);
    final pitchSweep = Mult.mono(input: pitchEnv.outlet, value: sweep);
    final pitch = Add.mono(input: pitchSweep.outlet, value: frequency);
    final osc = SineOscillator(frequency: .signal(pitch.outlet));

    final ampEnv = Decay.pure(trigger: trigger, time: decay);
    final amp = Mult.mono(input: osc.outlet, value: .signal(ampEnv.outlet));
    final velocityAmp = Mult.mono(
      input: amp.outlet,
      value: .signal(velocity.outlet),
    );

    final saturator = drive == null
        ? null
        : Saturator.mono(velocityAmp.outlet, drive: drive);

    return Kick._(
      velocity: velocity,
      pitchEnv: pitchEnv,
      pitchSweep: pitchSweep,
      pitch: pitch,
      osc: osc,
      ampEnv: ampEnv,
      amp: amp,
      velocityAmp: velocityAmp,
      saturator: saturator,
    );
  }
}
