import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Abs node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final mono = Abs.mono(oscA.outlet);
      expect(mono.inlets.length, equals(1));
      expect(mono.inlets[0].source, equals(oscA.outlet));
      expect(mono.outlets.length, equals(1));

      final stereo = Abs.stereo(oscA.outlet, oscB.outlet);
      expect(stereo.inlets.length, equals(2));
      expect(stereo.inlets[0].source, equals(oscA.outlet));
      expect(stereo.inlets[1].source, equals(oscB.outlet));
      expect(stereo.outlets.length, equals(2));
    });

    test('rectifies bipolar samples to absolute values in processor', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = AbsProcessor(numChannels: 1);

      final inBuf = Float32List.fromList([-1.0, -0.25, 0.0, 0.75]);
      final outBuf = Float32List(4);

      processor.process(context, [inBuf], [outBuf]);

      expect(outBuf[0], equals(1.0));
      expect(outBuf[1], equals(0.25));
      expect(outBuf[2], equals(0.0));
      expect(outBuf[3], equals(0.75));
    });

    test('.abs extension on Outlet produces Abs node', () {
      final osc = SineOscillator(frequency: const .value(440));
      final rectified = osc.outlet.abs;

      expect(rectified.node, isA<Abs>());
      expect(rectified.index, equals(0));
    });

    test('compiles and executes inside AudioPipeline converting bipolar to unipolar', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 128);
      final osc = SineOscillator(frequency: const .value(100));
      final rectified = osc.outlet.abs;
      final pipeline = compilePipeline(
        root: rectified.out,
        context: context,
      ).pipeline!;
      pipeline.process();
      final output = pipeline.outputs[0];

      expect(output.length, equals(128));
      expect(output.every((s) => s >= 0.0 && s <= 1.0), isTrue);
      // Peak of sine should still reach ~1.0
      expect(output.any((s) => s > 0.9), isTrue);
    });

    test('renders multi-channel stereo in AudioPipeline', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final oscL = SawtoothOscillator(frequency: const .value(110));
      final oscR = SawtoothOscillator(frequency: const .value(220));

      final stereo = Abs.stereo(oscL.outlet, oscR.outlet);
      final dac = Dac(channels: stereo.outlets);
      final pipeline = compilePipeline(root: dac, context: context).pipeline!;
      pipeline.process();
      expect(pipeline.outputs.length, equals(2));
      expect(pipeline.outputs[0].every((s) => s >= 0.0), isTrue);
      expect(pipeline.outputs[1].every((s) => s >= 0.0), isTrue);
    });
  });
}
