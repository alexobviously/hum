import 'package:dsp/dsp.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const blocks = sr * 5 ~/ vs; // 5 seconds
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final noisePitchLfo = SineOscillator(frequency: .value(0.8)).scale(200, 2000);
  final noisePitchLfo2 = Add(
    value: .value(200),
    channels: [noisePitchLfo.outlet],
  );
  final lfo2 = SineOscillator(frequency: .value(1));
  // final depth = Gain.mono(gain: .value(25), input: lfo.outlet); // ±25 Hz
  // final pitch = Offset.mono(
  //   value: .value(440),
  //   input: depth.outlet,
  // ); // 440 ± 25 Hz
  // final carrier = TriangleOscillator(frequency: .signal(pitchLfo.outlet));
  final noise = NoiseGenerator();
  final lp = OnePoleFilter(
    cutoff: .signal(noisePitchLfo.outlet),
    input: noise.outlet,
  );
  final hp = OnePoleFilter(
    cutoff: .signal(noisePitchLfo2.outlet),
    input: lp.outlet,
    type: .highpass,
  );
  final mult = Mult.mono(value: .value(0.7), input: hp.outlet);

  final pan = StereoPan(
    input: mult.outlet,
    pan: .signal(lfo2.outlet),
  );
  final wav = WavSink.file(
    channels: pan.outlets,
    path: 'tmp/pipeline_test14.wav',
  );
  final pipeline = compilePipeline(root: wav, context: context);

  for (int i = 0; i < blocks; i++) {
    pipeline.process();
  }

  pipeline.processorOf(wav).close();
}
