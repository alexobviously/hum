import 'package:dsp/dsp.dart';
import 'package:test/test.dart';

void main() {
  test('dsp library exports core symbols and builds simple graph', () {
    final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
    final sine = SineOscillator(frequency: 440);
    final gain = Gain.mono(gain: 0.8, input: sine.output);
    final pipeline = compilePipeline(root: gain, context: context);

    expect(pipeline.numChannels, equals(1));
    pipeline.process();
    expect(pipeline.outputs[0].length, equals(64));
  });
}
