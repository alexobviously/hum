import 'package:dsp/dsp.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(140);
  final blocks = tempo.blocksFor(bars: 4, sampleRate: sr, vectorSize: vs);
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);

  final clock = Clock.bpm(tempo.bpm);
  final adsr = Adsr(gate: clock.outlet, attack: .value(0.1));

  final low = Note.parse('A4');
  final high = Note.parse('E5');

  final ramp = SawtoothOscillator(
    frequency: .value(1 / tempo.bar),
    usePolyBlep: false,
  );

  final sine = SineOscillator(
    frequency: .signal(ramp.scale(low.hz, high.hz).outlet),
  );
  final saw = SawtoothOscillator(
    frequency: .signal(ramp.scale(low.hz / 2, high.hz / 2).outlet),
  );
  final noise = NoiseGenerator.pink();
  final amp = Gain.mono(
    gain: .signal(adsr.outlet),
    input: sine.outlet + saw.outlet * 0.1 + noise.outlet * 0.25,
  );
  final delay = Delay.mono(
    input: amp.outlet,
    time: .value(tempo.tripletEighth),
    feedback: .value(0.8),
    mix: .value(-0.7),
  );

  final wav = WavSink.file(
    channels: [delay.outlet],
    path: 'tmp/clock_test2.wav',
  );
  final pipeline = compilePipeline(root: wav, context: context);

  for (int i = 0; i < blocks; i++) {
    pipeline.process();
  }

  pipeline.processorOf(wav).close();
}
