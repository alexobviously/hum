import 'package:dsp/dsp.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const blocks = sr * 5 ~/ vs; // 5 seconds
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final pitchLfo = SineOscillator(frequency: .value(5))
      .scale(440 - 25, 440 + 25);
  final lfo2 = SineOscillator(frequency: .value(1));
  // final depth = Gain.mono(gain: .value(25), input: lfo.outlet); // ±25 Hz
  // final pitch = Offset.mono(
  //   value: .value(440),
  //   input: depth.outlet,
  // ); // 440 ± 25 Hz
  final carrier = SquareOscillator(frequency: .signal(pitchLfo.outlet));
  final gain = Gain.mono(gain: .value(0.7), input: carrier.outlet);

  final pan = StereoPan(
    input: gain.outlet,
    pan: .signal(lfo2.outlet),
  );
  final wav = WavSink.file(
    channels: pan.outlets,
    path: 'tmp/pipeline_test7.wav',
  );
  final pipeline = compilePipeline(root: wav, context: context);

  for (int i = 0; i < blocks; i++) {
    pipeline.process();
  }

  pipeline.processorOf(wav).close();
}
