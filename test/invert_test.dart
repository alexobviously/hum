import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Invert node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final mono = Invert.mono(oscA.outlet);
      expect(mono.inlets.length, equals(1));
      expect(mono.inlets[0].source, equals(oscA.outlet));
      expect(mono.outlets.length, equals(1));

      final stereo = Invert.stereo(oscA.outlet, oscB.outlet);
      expect(stereo.inlets.length, equals(2));
      expect(stereo.inlets[0].source, equals(oscA.outlet));
      expect(stereo.inlets[1].source, equals(oscB.outlet));
      expect(stereo.outlets.length, equals(2));
    });

    test('inverts sample polarity in processor', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = InvertProcessor(numChannels: 1);

      final inBuf = Float32List.fromList([1.0, -0.5, 0.0, 0.75]);
      final outBuf = Float32List(4);

      processor.process(context, [inBuf], [outBuf]);

      expect(outBuf[0], equals(-1.0));
      expect(outBuf[1], equals(0.5));
      expect(outBuf[2], equals(0.0));
      expect(outBuf[3], equals(-0.75));
    });

    test('unary operator - syntax creates Invert node', () {
      final osc = SineOscillator(frequency: const .value(440));
      final inverted = -osc.outlet;

      expect(inverted.node, isA<Invert>());
      expect(inverted.index, equals(0));
    });

    test(
      'summing a signal with its inverted self produces complete silence',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final osc = SawtoothOscillator(frequency: const .value(220));

        // Null test: S + (-S) == 0
        final cancelled = osc.outlet + (-osc.outlet);
        final pipeline = compilePipeline(
          root: cancelled.node,
          context: context,
        ).pipeline!;
        pipeline.process();
        final output = pipeline.outputs[0];

        expect(output.length, equals(64));
        for (int i = 0; i < 64; i++) {
          expect(output[i], closeTo(0.0, 1e-6));
        }
      },
    );

    test('compiles and renders inside multi-channel AudioPipeline', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final left = SineOscillator(frequency: const .value(440));
      final right = SineOscillator(frequency: const .value(880));

      final stereoInvert = Invert.stereo(left.outlet, right.outlet);
      final dac = Dac(channels: stereoInvert.outlets);
      final pipeline = compilePipeline(root: dac, context: context).pipeline!;
      pipeline.process();
      expect(pipeline.outputs.length, equals(2));
      expect(pipeline.outputs[0].length, equals(64));
      expect(pipeline.outputs[1].length, equals(64));
    });
  });
}
