import 'dart:math' as math;

import 'package:hum/hum.dart';

// TODO: declank

/// Available oscillator waveforms for [Swarm].
enum SwarmWaveform { sawtooth, sine, triangle, square }

/// A composite multi-oscillator cluster generator (supersaw, drone cluster).
///
/// Instantiates [voices] oscillators detuned symmetrically around [frequency],
/// spreads them across the stereo field using constant-power panning, and
/// normalizes their combined energy to prevent digital clipping.
///
/// Because [Swarm] is a graph composite, its internal oscillators are standard
/// nodes in the audio DAG:
/// - In-place parameter updates via [AudioHost.update] preserve oscillator phase continuity.
/// - Frequency modulation via audio-rate signals scales all voices in parallel.
/// - Internal oscillators and panners are accessible via [oscillators] and [panners].
class Swarm {
  /// Left stereo channel outlet.
  final Outlet left;

  /// Right stereo channel outlet.
  final Outlet right;

  /// Normalized mono outlet (sum of all voices).
  final Outlet outlet;

  /// Direct references to the internal voice oscillators.
  final List<OscillatorNode> oscillators;

  /// Direct references to the voice stereo panners.
  final List<StereoPan> panners;

  /// All internal graph nodes instantiated by this composite.
  final List<AudioNode> nodes;

  const Swarm._({
    required this.left,
    required this.right,
    required this.outlet,
    required this.oscillators,
    required this.panners,
    required this.nodes,
  });

  /// Creates a multi-oscillator swarm with the specified [waveform].
  factory Swarm({
    required ControlParam<double> frequency,
    SwarmWaveform waveform = .sawtooth,
    int voices = 7,
    double detuneCents = 20.0,
    double stereoSpread = 0.8,
  }) => Swarm.custom(
    frequency: frequency,
    voices: voices,
    detuneCents: detuneCents,
    stereoSpread: stereoSpread,
    builder: (voiceFreq) => switch (waveform) {
      .sawtooth => SawtoothOscillator(frequency: voiceFreq),
      .sine => SineOscillator(frequency: voiceFreq),
      .triangle => TriangleOscillator(frequency: voiceFreq),
      .square => SquareOscillator(frequency: voiceFreq),
    },
  );

  /// Classic supersaw cluster with rich harmonic density.
  factory Swarm.sawtooth({
    required ControlParam<double> frequency,
    int voices = 7,
    double detuneCents = 20.0,
    double stereoSpread = 0.8,
  }) => Swarm(
    frequency: frequency,
    waveform: .sawtooth,
    voices: voices,
    detuneCents: detuneCents,
    stereoSpread: stereoSpread,
  );

  /// Choral, warm sine drone cluster with shimmering acoustic beating.
  factory Swarm.sine({
    required ControlParam<double> frequency,
    int voices = 7,
    double detuneCents = 25.0,
    double stereoSpread = 0.8,
  }) => Swarm(
    frequency: frequency,
    waveform: .sine,
    voices: voices,
    detuneCents: detuneCents,
    stereoSpread: stereoSpread,
  );

  /// Warm analog triangle cluster with gentle odd harmonics.
  factory Swarm.triangle({
    required ControlParam<double> frequency,
    int voices = 7,
    double detuneCents = 20.0,
    double stereoSpread = 0.8,
  }) => Swarm(
    frequency: frequency,
    waveform: .triangle,
    voices: voices,
    detuneCents: detuneCents,
    stereoSpread: stereoSpread,
  );

  /// Hollow, woody square wave cluster.
  factory Swarm.square({
    required ControlParam<double> frequency,
    int voices = 7,
    double detuneCents = 20.0,
    double stereoSpread = 0.8,
  }) => Swarm(
    frequency: frequency,
    waveform: .square,
    voices: voices,
    detuneCents: detuneCents,
    stereoSpread: stereoSpread,
  );

  /// Creates a swarm using a custom oscillator builder function.
  factory Swarm.custom({
    required ControlParam<double> frequency,
    required OscillatorNode Function(ControlParam<double> frequency) builder,
    int voices = 7,
    double detuneCents = 20.0,
    double stereoSpread = 0.8,
  }) {
    assert(voices >= 1, 'Swarm must have at least 1 voice');

    final oscillators = <OscillatorNode>[];
    final panners = <StereoPan>[];
    final internalNodes = <AudioNode>[];

    final clampedSpread = stereoSpread.clamp(0.0, 1.0);

    for (int i = 0; i < voices; i++) {
      // Calculate normalized position x in [-1.0, 1.0]
      final double x = voices == 1 ? 0.0 : -1.0 + (2.0 * i) / (voices - 1);

      // Slight non-linear curve for dense core and wide edges
      final sign = x < 0.0 ? -1.0 : 1.0;
      final detuneCurve = sign * math.pow(x.abs(), 1.15).toDouble();
      final cents = detuneCurve * detuneCents;
      final ratio = math.pow(2.0, cents / 1200.0).toDouble();

      final pan = (x * clampedSpread).clamp(-1.0, 1.0);

      // Frequency calculation: static scalar or parallel signal modulation
      final ControlParam<double> voiceFreq;
      if (frequency.valueOrNull != null) {
        voiceFreq = .value(frequency.valueOrNull! * ratio);
      } else {
        final mult = frequency.outletOrNull!.mult(ratio);
        internalNodes.add(mult);
        voiceFreq = .signal(mult.outlet);
      }

      final osc = builder(voiceFreq);
      oscillators.add(osc);
      internalNodes.add(osc);

      final panner = StereoPan(input: osc.outlet, pan: .value(pan));
      panners.add(panner);
      internalNodes.add(panner);
    }

    // Headroom scaling factor (1 / N) guarantees maximum peak stays <= 1.0
    final gain = 1.0 / voices;

    final leftSum = Sum(inputs: [for (final p in panners) p.left]);
    final rightSum = Sum(inputs: [for (final p in panners) p.right]);
    final monoSum = Sum(inputs: [for (final o in oscillators) o.outlet]);

    internalNodes.add(leftSum);
    internalNodes.add(rightSum);
    internalNodes.add(monoSum);

    final leftScaled = leftSum.outlet.mult(gain);
    final rightScaled = rightSum.outlet.mult(gain);
    final monoScaled = monoSum.outlet.mult(gain);

    internalNodes.add(leftScaled);
    internalNodes.add(rightScaled);
    internalNodes.add(monoScaled);

    return Swarm._(
      left: leftScaled.outlet,
      right: rightScaled.outlet,
      outlet: monoScaled.outlet,
      oscillators: oscillators,
      panners: panners,
      nodes: internalNodes,
    );
  }
}

/// Convenience extension on [Note] for creating swarms.
extension NoteSwarmExtension on Note {
  /// Creates a multi-oscillator swarm centered on this note's fundamental frequency.
  Swarm swarm({
    SwarmWaveform waveform = .sawtooth,
    int voices = 7,
    double detuneCents = 20.0,
    double stereoSpread = 0.8,
  }) => Swarm(
    frequency: .value(hz),
    waveform: waveform,
    voices: voices,
    detuneCents: detuneCents,
    stereoSpread: stereoSpread,
  );
}
