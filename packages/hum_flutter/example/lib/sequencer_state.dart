import 'dart:math' as math;

import 'package:hum/hum.dart';
import 'package:hum_flutter/hum_flutter.dart';

const availableKeys = <String>[
  'C4',
  'C#4',
  'D4',
  'D#4',
  'E4',
  'F4',
  'F#4',
  'G4',
  'G#4',
  'A4',
  'A#4',
  'B4',
];

const availableScales = <ScalePattern>[
  .major,
  .minor,
  .dorian,
  .phrygian,
  .lydian,
  .mixolydian,
  .locrian,
  .harmonicMinor,
  .melodicMinor,
  .majorPentatonic,
  .minorPentatonic,
  .blues,
  .wholeTone,
];

/// Holds the step sequencer pattern, synth parameters, and builds the `hum`
/// DSP graph.
class SequencerState {
  static const int numSteps = 8;
  static const int numNotes = 7;

  // Which note index (0..numNotes-1) is active per step, or null for a rest.
  final List<int?> steps = [0, 2, 4, 2, 5, 4, 3, 1];

  String rootKey = 'A4';
  ScalePattern scalePattern = .major;
  double bpm = 120;

  // Envelope
  double attack = 0.015;
  double decay = 0.18;
  double sustain = 0.35;
  double release = 0.12;

  // 3-waveform oscillator mix (inspired by hum's interactive arp demo)
  double sineLevel = 0.55;
  double squareLevel = 0.2;
  double sawLevel = 0.3;

  // Filter & FX
  double cutoff = 2400;
  double resonance = 2.0;
  double delayMix = 0.2;
  double delayFeedback = 0.35;
  double reverbMix = 0.25;

  // Bitcrusher
  bool bitcrushEnabled = false;
  double bitDepth = 8;
  double downsample = 4;
  double bitcrushMix = 0.8;

  List<Note> get notes =>
      scalePattern.at(.parse(rootKey)).take(numNotes).toList();

  void toggleCell(int step, int noteIdx) {
    steps[step] = steps[step] == noteIdx ? null : noteIdx;
  }

  void randomizeSequence() {
    final rng = math.Random();
    for (int i = 0; i < numSteps; i++) {
      steps[i] = rng.nextDouble() < 0.2 ? null : rng.nextInt(numNotes);
    }
  }

  void clearSequence() {
    steps.fillRange(0, numSteps, null);
  }

  void randomizeSettings() {
    final rng = math.Random();
    double range(double min, double max) =>
        min + rng.nextDouble() * (max - min);

    rootKey = availableKeys[rng.nextInt(availableKeys.length)];
    scalePattern = availableScales[rng.nextInt(availableScales.length)];
    bpm = range(80, 175).roundToDouble();

    attack = range(0.002, 0.12);
    decay = range(0.05, 0.45);
    sustain = range(0.05, 0.75);
    release = range(0.03, 0.4);

    sineLevel = range(0.1, 0.9);
    squareLevel = range(0.0, 0.7);
    sawLevel = range(0.0, 0.8);

    cutoff = range(400, 9000);
    resonance = range(0.7, 4.5);
    delayMix = range(0.0, 0.55);
    delayFeedback = range(0.1, 0.95);
    reverbMix = range(0.05, 0.9);

    bitcrushEnabled = rng.nextDouble() < 0.35;
    if (bitcrushEnabled) {
      bitDepth = range(3, 12).roundToDouble();
      downsample = range(1.5, 10.0);
      bitcrushMix = range(0.3, 0.9);
    }
  }

  AudioNode buildGraph(HumAudioSession session) {
    final currentNotes = notes;
    final tempo = Tempo(bpm);

    final clock = Clock(
      frequency: .value(1 / tempo.eighth),
      pulseWidth: const .value(0.5),
    );

    final freqSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: [
        for (final noteIdx in steps) currentNotes[noteIdx ?? 0].hz,
      ],
    );

    // 1.0 for active steps, 0.0 for rests — multiplied with clock.gate so
    // empty columns stay silent while delay/reverb tails ring out.
    final gateSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: [
        for (final noteIdx in steps) noteIdx != null ? 1.0 : 0.0,
      ],
    );

    final stepGate = Mult.mono(
      input: clock.gate,
      value: .signal(gateSeq.outlet),
    );

    final sine = SineOscillator(
      frequency: .signal(freqSeq.outlet),
    ).outlet.mult(sineLevel);

    final square = SquareOscillator(
      frequency: .signal(freqSeq.outlet),
    ).outlet.mult(squareLevel);

    final saw = SawtoothOscillator(
      frequency: .signal(freqSeq.outlet),
    ).outlet.mult(sawLevel);

    final mixed = (sine.outlet + square.outlet + saw.outlet).clip(1.0);

    final filter = SvfFilter(
      input: mixed,
      cutoff: .value(cutoff),
      resonance: .value(resonance),
    );

    final env = Adsr(
      gate: stepGate.outlet,
      attack: .value(attack),
      decay: .value(decay),
      sustain: .value(sustain),
      release: .value(release),
      curve: .exponential,
    );

    final voiced = Mult.mono(
      input: filter.lowpass,
      value: .signal(env.outlet),
    );

    final crushed = Bitcrusher.mono(
      input: voiced.outlet,
      bitDepth: .value(bitDepth),
      downsample: .value(downsample),
      mix: .value(bitcrushEnabled ? bitcrushMix : 0.0),
    );

    final delay = Delay.mono(
      input: crushed.outlet,
      time: .value(tempo.dottedSixteenth),
      feedback: .value(delayFeedback),
      mix: .value(delayMix),
    );

    final reverb = Freeverb.mono(
      input: delay.outlet,
      roomSize: const .value(0.65),
      damp: const .value(0.4),
      mix: .value(reverbMix),
    );

    final master = Mult.stereo(
      leftInput: reverb.left,
      rightInput: reverb.right,
      value: const .value(0.5),
    );

    final outCh = session.outputChannels;
    final channels = outCh <= 1
        ? [master.outlets[0]]
        : [
            master.outlets[0],
            master.outlets[1],
            for (int c = 2; c < outCh; c++) master.outlets[0],
          ];
    return Out(channels: channels);
  }
}
