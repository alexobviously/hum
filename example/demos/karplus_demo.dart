import 'package:hum/hum.dart';

void main() {
  const sr = 44100;
  const vs = 64;
  const tempo = Tempo(140);
  final blocks = tempo.blocksFor(bars: 4, sampleRate: sr, vectorSize: vs);
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final clock = Clock.bpm(tempo.bpm);
  final note = Note.parse('C4');

  final node = KarplusStrong(
    gate: clock.gate,
    frequency: .value(note.hz),
    feedback: const .value(0.997),
  );

  final bitcrusher = Bitcrusher.mono(
    input: node.outlet,
    downsample: .value(4),
    bitDepth: .value(6),
    mix: .value(0.75),
  );

  final verb = Freeverb.mono(input: bitcrusher.outlet);

  // final delay = Delay.mono(
  //   input: bitcrusher.outlet,
  //   time: .value(tempo.durationOf(NoteValue.sixteenth, triplet: true)),
  //   feedback: const .value(0.74),
  //   mix: .value(0),
  //   damp: const .value(0.8),
  // );

  final wav = WavSink.file(
    channels: verb.outlets,
    path: 'tmp/karplus_test_fv.wav',
  );
  final pipeline = compilePipeline(root: wav, context: context).pipeline!;
  for (int i = 0; i < blocks; i++) {
    pipeline.process();
  }

  pipeline.processorOf(wav).close();
}
