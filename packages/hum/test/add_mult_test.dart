import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Add node', () {
    test('declares expected inlets and outlets', () {
      final osc = SineOscillator(frequency: .value(440));
      final add = Add.mono(value: .value(0.5), input: osc.outlet);

      expect(add.inlets.length, equals(2));
      expect(add.inlets[Add.valueInlet].source, isNull);
      expect(add.inlets[1].source, equals(osc.outlet));
      expect(add.outlets.length, equals(1));
    });

    test('adds constant scalar offset', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = AddProcessor(value: 0.5, numChannels: 1);

      final inBuf = Float32List.fromList([0.0, 0.25, -0.5, 0.5]);
      final outBuf = Float32List(4);

      processor.process(context, [Float32List(4), inBuf], [outBuf]);

      expect(outBuf[0], closeTo(0.5, 1e-6));
      expect(outBuf[1], closeTo(0.75, 1e-6));
      expect(outBuf[2], closeTo(0.0, 1e-6));
      expect(outBuf[3], closeTo(1.0, 1e-6));
    });

    test('adds audio-rate signal offset', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = AddProcessor(value: null, numChannels: 1);

      final valBuf = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);
      final inBuf = Float32List.fromList([1.0, 1.0, 1.0, 1.0]);
      final outBuf = Float32List(4);

      processor.process(context, [valBuf, inBuf], [outBuf]);

      expect(outBuf[0], closeTo(1.1, 1e-6));
      expect(outBuf[1], closeTo(1.2, 1e-6));
      expect(outBuf[2], closeTo(1.3, 1e-6));
      expect(outBuf[3], closeTo(1.4, 1e-6));
    });

    test('compiles and executes inside AudioPipeline', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final osc = SineOscillator(frequency: const .value(440));
      final add = Add.mono(value: const .value(0.5), input: osc.outlet);
      final pipeline = compilePipeline(root: add, context: context).pipeline!;
      pipeline.process();
      final out = pipeline.outputs[0];
      expect(out.length, equals(64));
      // DC shifted sine should oscillate around 0.5
      expect(out.every((s) => s >= -0.51 && s <= 1.51), isTrue);
    });
  });

  group('Mult node', () {
    test('declares expected inlets and outlets', () {
      final osc = SineOscillator(frequency: .value(440));
      final mult = Mult.mono(value: .value(0.5), input: osc.outlet);

      expect(mult.inlets.length, equals(2));
      expect(mult.inlets[Mult.valueInlet].source, isNull);
      expect(mult.inlets[1].source, equals(osc.outlet));
      expect(mult.outlets.length, equals(1));
    });

    test('multiplies constant scalar factor', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = MultProcessor(value: 0.5, numChannels: 1);

      final inBuf = Float32List.fromList([0.0, 1.0, -0.5, 0.8]);
      final outBuf = Float32List(4);

      processor.process(context, [Float32List(4), inBuf], [outBuf]);

      expect(outBuf[0], closeTo(0.0, 1e-6));
      expect(outBuf[1], closeTo(0.5, 1e-6));
      expect(outBuf[2], closeTo(-0.25, 1e-6));
      expect(outBuf[3], closeTo(0.4, 1e-6));
    });

    test('multiplies audio-rate signal (ring modulation / AM)', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = MultProcessor(value: null, numChannels: 1);

      final carrierBuf = Float32List.fromList([0.5, -0.5, 1.0, -1.0]);
      final modBuf = Float32List.fromList([0.5, 0.5, -0.5, -0.5]);
      final outBuf = Float32List(4);

      processor.process(context, [modBuf, carrierBuf], [outBuf]);

      expect(outBuf[0], closeTo(0.25, 1e-6));
      expect(outBuf[1], closeTo(-0.25, 1e-6));
      expect(outBuf[2], closeTo(-0.5, 1e-6));
      expect(outBuf[3], closeTo(0.5, 1e-6));
    });

    test('compiles and executes inside AudioPipeline with scalar and audio-rate mod', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final carrier = SineOscillator(frequency: const .value(440));
      final modulator = SineOscillator(frequency: const .value(100));

      final ringMod = Mult.mono(
        value: ControlParam.signal(modulator.outlet),
        input: carrier.outlet,
      );
      final scaled = Mult.mono(value: const .value(0.5), input: ringMod.outlet);
      final pipeline = compilePipeline(
        root: scaled,
        context: context,
      ).pipeline!;
      pipeline.process();
      final out = pipeline.outputs[0];
      expect(out.length, equals(64));
      expect(out.every((s) => s >= -0.501 && s <= 0.501), isTrue);
    });

    test('interpolates gain smoothly on update when interpTime > 0', () {
      const sampleRate = 1000;
      const vectorSize = 32;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final proc = MultProcessor(
        value: 0.0,
        numChannels: 1,
        interpTime: 0.05, // 50 samples ramp
      );

      final dummyInlet = Float32List(vectorSize);
      final inBuf = Float32List(vectorSize);
      inBuf.fillRange(0, vectorSize, 1.0); // Constant 1.0 DC
      final outBuf = Float32List(vectorSize);

      proc.process(context, [dummyInlet, inBuf], [outBuf]);
      expect(outBuf[0], equals(0.0));

      // Update target gain from 0.0 to 1.0
      proc.update((value: 1.0, interpTime: 0.05));
      proc.process(context, [dummyInlet, inBuf], [outBuf]);

      // Instead of instantly jumping to 1.0, it ramps upwards
      expect(outBuf[0], greaterThan(0.0));
      expect(outBuf[0], lessThan(0.5));
      expect(outBuf[vectorSize - 1], greaterThan(outBuf[0]));
      expect(outBuf[vectorSize - 1], lessThan(1.0));

      // After settling, output reaches exactly 1.0
      for (int i = 0; i < 10; i++) {
        proc.process(context, [dummyInlet, inBuf], [outBuf]);
      }
      expect(outBuf[0], closeTo(1.0, 1e-4));
    });

    test('snaps gain immediately when interpTime is 0.0', () {
      const sampleRate = 1000;
      const vectorSize = 32;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final proc = MultProcessor(
        value: 0.0,
        numChannels: 1,
        interpTime: 0.0,
      );

      final dummyInlet = Float32List(vectorSize);
      final inBuf = Float32List(vectorSize);
      inBuf.fillRange(0, vectorSize, 1.0);
      final outBuf = Float32List(vectorSize);

      proc.process(context, [dummyInlet, inBuf], [outBuf]);

      proc.update((value: 1.0, interpTime: 0.0));
      proc.process(context, [dummyInlet, inBuf], [outBuf]);

      // All samples in block are immediately 1.0
      for (int i = 0; i < vectorSize; i++) {
        expect(outBuf[i], closeTo(1.0, 1e-5));
      }
    });
  });
}
