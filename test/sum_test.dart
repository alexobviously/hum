import 'dart:typed_data';

import 'package:dsp/dsp.dart';
import 'package:test/test.dart';

void main() {
  group('Sum node', () {
    test('declares expected inlets and outlets', () {
      final osc1 = SineOscillator(frequency: const .value(440));
      final osc2 = SineOscillator(frequency: const .value(880));
      final osc3 = SineOscillator(frequency: const .value(1320));

      final sum = Sum(inputs: [osc1.outlet, osc2.outlet, osc3.outlet]);

      expect(sum.inlets.length, equals(3));
      expect(sum.inlets[0].source, equals(osc1.outlet));
      expect(sum.inlets[1].source, equals(osc2.outlet));
      expect(sum.inlets[2].source, equals(osc3.outlet));
      expect(sum.outlets.length, equals(1));
      expect(sum.outlet, equals(sum.outlets.first));
    });

    test('operator + syntax builds Sum node', () {
      final osc1 = SineOscillator(frequency: const .value(440));
      final osc2 = SineOscillator(frequency: const .value(880));

      final combined = osc1.outlet + osc2.outlet;

      expect(combined.node, isA<Sum>());
      final sumNode = combined.node as Sum;
      expect(sumNode.inputs, equals([osc1.outlet, osc2.outlet]));
    });

    test('processor handles 0, 1, 2, and N inputs', () {
      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      // 0 inputs -> silence
      final p0 = SumProcessor(numInputs: 0);
      final out0 = Float32List(vectorSize);
      out0.fillRange(0, vectorSize, 99.0);
      p0.process(context, [], [out0]);
      for (int i = 0; i < vectorSize; i++) {
        expect(out0[i], equals(0.0));
      }

      // 1 input -> copy
      final p1 = SumProcessor(numInputs: 1);
      final in1 = Float32List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final out1 = Float32List(vectorSize);
      p1.process(context, [in1], [out1]);
      expect(out1, equals(in1));

      // 2 inputs -> addition
      final p2 = SumProcessor(numInputs: 2);
      final inA = Float32List.fromList([1, 1, 1, 1, 2, 2, 2, 2]);
      final inB = Float32List.fromList([3, 3, 3, 3, 4, 4, 4, 4]);
      final out2 = Float32List(vectorSize);
      p2.process(context, [inA, inB], [out2]);
      for (int i = 0; i < 4; i++) {
        expect(out2[i], closeTo(4.0, 1e-6));
        expect(out2[i + 4], closeTo(6.0, 1e-6));
      }

      // 4 inputs -> accumulation
      final p4 = SumProcessor(numInputs: 4);
      final inC = Float32List.fromList([10, 10, 10, 10, 10, 10, 10, 10]);
      final inD = Float32List.fromList([
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        100,
      ]);
      final out4 = Float32List(vectorSize);
      p4.process(context, [inA, inB, inC, inD], [out4]);
      for (int i = 0; i < 4; i++) {
        expect(out4[i], closeTo(114.0, 1e-6));
        expect(out4[i + 4], closeTo(116.0, 1e-6));
      }
    });

    test('compiles and executes in pipeline', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final osc1 = SineOscillator(frequency: const .value(100));
      final osc2 = SineOscillator(frequency: const .value(200));

      final sum = osc1.outlet + osc2.outlet;
      final sink = WavSink.memory(channels: [sum]);

      final pipeline = compilePipeline(root: sink, context: context);
      pipeline.process();

      final wavProcessor = pipeline.processorOf(sink);
      final bytes = wavProcessor.close();
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(44));
    });
  });
}
