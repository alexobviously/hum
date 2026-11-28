import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Clamp node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final mono = Clamp.mono(
        oscA.outlet,
        min: const .value(-0.5),
        max: const .value(0.5),
      );
      expect(mono.inlets.length, equals(3));
      expect(mono.inlets[Clamp.minInlet].source, isNull);
      expect(mono.inlets[Clamp.maxInlet].source, isNull);
      expect(mono.inlets[Clamp.audioInletOffset].source, equals(oscA.outlet));
      expect(mono.outlets.length, equals(1));

      final stereo = Clamp.stereo(
        oscA.outlet,
        oscB.outlet,
        min: const .value(-0.5),
        max: const .value(0.5),
      );
      expect(stereo.inlets.length, equals(4));
      expect(stereo.inlets[Clamp.audioInletOffset].source, equals(oscA.outlet));
      expect(
        stereo.inlets[Clamp.audioInletOffset + 1].source,
        equals(oscB.outlet),
      );
      expect(stereo.outlets.length, equals(2));
    });

    test('processor clamps two-sided bounds accurately', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 8);
      final processor = ClampProcessor(
        numChannels: 1,
        min: -0.5,
        max: 0.5,
      );

      final inBuf = Float32List.fromList([
        -1.2,
        -0.5,
        0.0,
        0.5,
        1.2,
        -2.0,
        2.0,
        0.2,
      ]);
      final outBuf = Float32List(8);

      processor.process(
        context,
        [Float32List(8), Float32List(8), inBuf],
        [outBuf],
      );

      expect(outBuf[0], closeTo(-0.5, 1e-6));
      expect(outBuf[1], closeTo(-0.5, 1e-6));
      expect(outBuf[2], closeTo(0.0, 1e-6));
      expect(outBuf[3], closeTo(0.5, 1e-6));
      expect(outBuf[4], closeTo(0.5, 1e-6));
      expect(outBuf[5], closeTo(-0.5, 1e-6));
      expect(outBuf[6], closeTo(0.5, 1e-6));
      expect(outBuf[7], closeTo(0.2, 1e-6));
    });

    test(
      'processor supports floor-only bounding (diode/half-wave rectifier)',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
        final processor = ClampProcessor(
          numChannels: 1,
          min: 0.0,
          max: null,
        );

        final inBuf = Float32List.fromList([-1.0, -0.2, 0.3, 1.5]);
        final outBuf = Float32List(4);

        processor.process(
          context,
          [Float32List(4), Float32List(4), inBuf],
          [outBuf],
        );

        expect(outBuf[0], equals(0.0));
        expect(outBuf[1], equals(0.0));
        expect(outBuf[2], closeTo(0.3, 1e-6));
        expect(outBuf[3], closeTo(1.5, 1e-6));
      },
    );

    test('processor supports ceiling-only peak limiting', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = ClampProcessor(
        numChannels: 1,
        min: null,
        max: 0.8,
      );

      final inBuf = Float32List.fromList([-1.5, -0.2, 0.5, 1.2]);
      final outBuf = Float32List(4);

      processor.process(
        context,
        [Float32List(4), Float32List(4), inBuf],
        [outBuf],
      );

      expect(outBuf[0], closeTo(-1.5, 1e-6));
      expect(outBuf[1], closeTo(-0.2, 1e-6));
      expect(outBuf[2], closeTo(0.5, 1e-6));
      expect(outBuf[3], closeTo(0.8, 1e-6));
    });

    test('Clamp.bipolar factory clips symmetrically to threshold', () {
      final osc = SineOscillator(frequency: const .value(440));
      final clamped = Clamp.bipolar(osc.outlet, threshold: 0.4);

      expect(clamped.min?.valueOrNull, equals(-0.4));
      expect(clamped.max?.valueOrNull, equals(0.4));
    });

    test('Clamp.unipolar factory bounds to 0.0 .. 1.0', () {
      final osc = SineOscillator(frequency: const .value(440));
      final clamped = Clamp.unipolar(osc.outlet);

      expect(clamped.min?.valueOrNull, equals(0.0));
      expect(clamped.max?.valueOrNull, equals(1.0));
    });

    test('.clip() and .clamp() extension syntax produce Clamp nodes', () {
      final osc = SineOscillator(frequency: const .value(440));
      final clipped = osc.outlet.clip(0.6);
      expect(clipped.node, isA<Clamp>());

      final clamped = osc.outlet.clamp(min: -0.2, max: 0.7);
      expect(clamped.node, isA<Clamp>());
    });

    test('compiles and executes inside AudioPipeline with live updates', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final saw = SawtoothOscillator(frequency: const .value(100));
      final clamp = Clamp.bipolar(saw.outlet, threshold: 0.5);
      final pipeline = compilePipeline(root: clamp, context: context).pipeline!;
      pipeline.process();
      final out = pipeline.outputs[0];
      expect(out.every((s) => s >= -0.501 && s <= 0.501), isTrue);

      // Live update threshold to 0.2
      final updated = Clamp.bipolar(saw.outlet, threshold: 0.2);
      pipeline.update(clamp, updated);

      pipeline.process();
      final outUpdated = pipeline.outputs[0];
      expect(outUpdated.every((s) => s >= -0.201 && s <= 0.201), isTrue);
    });

    test('handles dynamic audio-rate threshold modulation', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final saw = SawtoothOscillator(frequency: const .value(100));
      final mod = SineOscillator(frequency: const .value(10))
          .mapRange(0.1, 0.8);

      final clamp = Clamp.mono(
        saw.outlet,
        min: const .value(-0.5),
        max: ControlParam.signal(mod.outlet),
      );
      final pipeline = compilePipeline(root: clamp, context: context).pipeline!;
      pipeline.process();
      final out = pipeline.outputs[0];
      expect(out.every((s) => s >= -0.501 && s <= 0.801), isTrue);
    });

    test('fastClamp and clampDouble clamp accurately without boxing', () {
      expect(1.5.fastClamp(-1.0, 1.0), equals(1.0));
      expect((-1.5).fastClamp(-1.0, 1.0), equals(-1.0));
      expect(0.25.fastClamp(-1.0, 1.0), equals(0.25));

      expect(clampDouble(1.5, -1.0, 1.0), equals(1.0));
      expect(clampDouble(-1.5, -1.0, 1.0), equals(-1.0));
      expect(clampDouble(0.25, -1.0, 1.0), equals(0.25));

      expect(15.fastClamp(0, 10), equals(10));
      expect((-5).fastClamp(0, 10), equals(0));
      expect(5.fastClamp(0, 10), equals(5));
    });
  });
}
