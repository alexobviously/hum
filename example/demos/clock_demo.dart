import 'package:hum/hum.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(140);
  final blocks = tempo.blocksFor(bars: 4, sampleRate: sr, vectorSize: vs);
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);

  final clock = Clock.bpm(tempo.bpm);
  final adsr = Adsr(gate: clock.gate, attack: .value(0.1));

  final low = Note.parse('A4');
  final high = Note.parse('E5');

  final ramp = SawtoothOscillator(
    frequency: .value(1 / tempo.bar),
    usePolyBlep: false,
  );

  final sine = SineOscillator(
    frequency: .signal(ramp.mapRange(low.hz, high.hz).outlet),
  );
  final saw = SawtoothOscillator(
    frequency: .signal(ramp.mapRange(low.hz / 2, high.hz / 2).outlet),
  );
  final noise = NoiseGenerator.pink();
  final sawScaled = Mult.mono(value: const .value(0.1), input: saw.outlet);
  final noiseScaled = Mult.mono(value: const .value(0.25), input: noise.outlet);
  final amp = Mult.mono(
    value: ControlParam.signal(adsr.outlet),
    input: sine.outlet + sawScaled.outlet + noiseScaled.outlet,
  );
  final bitcrush = Bitcrusher.mono(
    input: amp.outlet,
    bitDepth: .value(4),
    downsample: .value(0.5),
  );
  final delay = Delay.mono(
    input: bitcrush.outlet,
    time: .value(tempo.tripletEighth),
    feedback: .value(0.8),
    mix: .value(0.15),
  );

  final wav = WavSink.file(
    channels: [delay.outlet],
    path: 'tmp/clock_test3.wav',
  );
  final pipeline = compilePipeline(root: wav, context: context).pipeline!;
  for (int i = 0; i < blocks; i++) {
    pipeline.process();
  }

  pipeline.processorOf(wav).close();
}
