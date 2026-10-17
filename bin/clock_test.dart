import 'package:dsp/dsp.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const bpm = 140.0;
  const blocks = 2 * 4 * (sr * 60 ~/ (bpm * vs)); // 2 bars
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);

  final clock = Clock.bpm(bpm);
  final adsr = Adsr(gate: clock.outlet);

  final sine = SineOscillator(frequency: .value(440));
  final noise = NoiseGenerator.pink();
  final amp = Gain.mono(
    gain: .signal(adsr.outlet),
    input: sine.outlet + noise.outlet,
  );

  final wav = WavSink.file(
    channels: [amp.outlet],
    path: 'tmp/clock_test.wav',
  );
  final pipeline = compilePipeline(root: wav, context: context);

  for (int i = 0; i < blocks; i++) {
    pipeline.process();
  }

  pipeline.processorOf(wav).close();
}
