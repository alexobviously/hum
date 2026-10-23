import 'package:hum/hum.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(128);

  // Render 4 bars of sequence
  final blocks = tempo.blocksFor(bars: 4, sampleRate: sr, vectorSize: vs);
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);

  // 1. Clock running at 16th notes with 50% duty cycle
  final clock = Clock(
    frequency: .value(1 / tempo.sixteenth),
    pulseWidth: const .value(0.5),
  );

  // 2. An 8-step melodic acid bassline (notes in Hz)
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

  // 3. Portamento / Slew on pitch: subtle 15ms glide between notes, starting on the first note
  final pitchCv = seq.cv.slew(0.015, bassNotes.first);

  // 4. Synth Voice: Sawtooth driven by the slewed step pitch
  final saw = SawtoothOscillator(
    frequency: .signal(pitchCv.outlet),
  );

  // 5. Envelope: Punchy bass articulation gated by the clock's pulse width
  final ampEnv = Adsr(
    gate: clock.gate,
    attack: const .value(0.005),
    decay: .value(tempo.sixteenth * 0.9),
    sustain: const .value(0.1),
    release: const .value(0.02),
    curve: .exponential,
  );

  // 6. Resonant Lowpass Filter with envelope modulation
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

  // 7. Stereo Delay for space
  final delay = Delay.stereo(
    leftInput: voiced.outlet,
    rightInput: voiced.outlet,
    time: .value(tempo.dottedSixteenth),
    feedback: const .value(0.4),
    mix: const .value(0.25),
  );

  // 8. Master Gain (prevent resonant filter peaks from clipping):
  final master = Mult.stereo(
    value: const .value(0.4),
    leftInput: delay.outlets[0],
    rightInput: delay.outlets[1],
  );

  // 9. Output to WAV file
  final wav = WavSink.file(
    channels: master.outlets,
    path: 'tmp/step_sequencer_demo.wav',
  );

  final pipeline = compilePipeline(root: wav, context: context).pipeline!;
  print('Rendering 4 bars of step sequencer demo at 128 BPM...');
  for (int i = 0; i < blocks; i++) {
    pipeline.process();
  }

  pipeline.processorOf(wav).close();
  print('WAV rendered successfully to tmp/step_sequencer_demo.wav!');
}
