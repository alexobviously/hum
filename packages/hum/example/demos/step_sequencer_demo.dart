import 'package:hum/hum.dart';

import '../harness.dart';

void main(List<String> args) => runDemo(
  name: 'step_sequencer_demo',
  tempo: const Tempo(128),
  bars: 4,
  description:
      'Acid bassline step sequencer with portamento glide and stereo delay.',
  args: args,
  builder: (context, tempo, _) {
    // Clock running at 16th notes with 50% duty cycle
    final clock = Clock(
      frequency: .value(1 / tempo.sixteenth),
      pulseWidth: const .value(0.5),
    );

    // An 8-step melodic acid bassline (notes in Hz)
    final bassNotes = [
      Note.parse('D2').hz,
      Note.parse('D2').hz,
      Note.parse('F2').hz,
      Note.parse('D2').hz,
      Note.parse('G2').hz,
      Note.parse('A2').hz,
      Note.parse('C3').hz,
      Note.parse('A2').hz,
    ];

    final seq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: bassNotes,
    );

    // Portamento / Slew on pitch: subtle 15ms glide between notes
    final pitchCv = seq.cv.slew(0.015, bassNotes.first);

    // Synth Voice: Sawtooth driven by the slewed step pitch
    final saw = SawtoothOscillator(
      frequency: .signal(pitchCv.outlet),
    );

    // Envelope: Punchy bass articulation gated by the clock's pulse width
    final ampEnv = Adsr(
      gate: clock.gate,
      attack: const .value(0.005),
      decay: .value(tempo.sixteenth * 0.9),
      sustain: const .value(0.1),
      release: const .value(0.02),
      curve: .exponential,
    );

    // Resonant Lowpass Filter with envelope modulation
    final filter = SvfFilter(
      input: saw.outlet,
      cutoff: const .value(1200.0),
      resonance: const .value(2.5),
    );

    // Apply amplitude envelope
    final voiced = Mult.mono(
      value: ControlParam.signal(ampEnv.outlet),
      input: filter.lowpass,
    );

    // Stereo Delay for space
    final delay = Delay.stereo(
      leftInput: voiced.outlet,
      rightInput: voiced.outlet,
      time: .value(tempo.dottedSixteenth),
      feedback: const .value(0.4),
      mix: const .value(0.25),
    );

    // Master Gain (prevent resonant filter peaks from clipping):
    return Mult.stereo(
      value: const .value(0.4),
      leftInput: delay.outlets[0],
      rightInput: delay.outlets[1],
    );
  },
);
