import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Crossfade node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final mono = Crossfade.mono(a: oscA.outlet, b: oscB.outlet);
      expect(mono.inlets.length, equals(3)); // mix, a, b
      expect(mono.inlets[Crossfade.mixInlet].source, isNull);
      expect(
        mono.inlets[Crossfade.audioInletOffset].source,
        equals(oscA.outlet),
      );
      expect(
        mono.inlets[Crossfade.audioInletOffset + 1].source,
        equals(oscB.outlet),
      );
      expect(mono.outlets.length, equals(1));

      final oscALeft = SineOscillator(frequency: const .value(440));
      final oscARight = SineOscillator(frequency: const .value(442));
      final oscBLeft = SineOscillator(frequency: const .value(880));
      final oscBRight = SineOscillator(frequency: const .value(882));

      final stereo = Crossfade.stereo(
        aLeft: oscALeft.outlet,
        aRight: oscARight.outlet,
        bLeft: oscBLeft.outlet,
        bRight: oscBRight.outlet,
      );
      expect(stereo.inlets.length, equals(5)); // mix, aL, aR, bL, bR
      expect(stereo.outlets.length, equals(2));
      expect(stereo.left, equals(stereo.outlets[0]));
      expect(stereo.right, equals(stereo.outlets[1]));
    });

    test('blends correctly in linear mode at mix -1.0, 0.0, and +1.0', () {
      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      final inA = Float32List.fromList([10, 10, 10, 10, 10, 10, 10, 10]);
      final inB = Float32List.fromList([20, 20, 20, 20, 20, 20, 20, 20]);
      final out = Float32List(vectorSize);

      // Mix -1.0 -> all A
      final p0 = CrossfadeProcessor(
        numChannels: 1,
        mix: -1.0,
        mode: CrossfadeMode.linear,
      );
      p0.process(context, [inA, inB], [out]);
      for (int i = 0; i < vectorSize; i++) {
        expect(out[i], closeTo(10.0, 1e-5));
      }

      // Mix +1.0 -> all B
      final p1 = CrossfadeProcessor(
        numChannels: 1,
        mix: 1.0,
        mode: CrossfadeMode.linear,
      );
      p1.process(context, [inA, inB], [out]);
      for (int i = 0; i < vectorSize; i++) {
        expect(out[i], closeTo(20.0, 1e-5));
      }

      // Mix 0.0 (centre) -> 50% A + 50% B = 15.0
      final pHalf = CrossfadeProcessor(
        numChannels: 1,
        mix: 0.0,
        mode: CrossfadeMode.linear,
      );
      pHalf.process(context, [inA, inB], [out]);
      for (int i = 0; i < vectorSize; i++) {
        expect(out[i], closeTo(15.0, 1e-5));
      }
    });

    test('blends correctly in equal-power mode at centre (mix = 0.0)', () {
      const vectorSize = 4;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      final inA = Float32List.fromList([1, 1, 1, 1]);
      final inB = Float32List.fromList([1, 1, 1, 1]);
      final out = Float32List(vectorSize);

      // At mix = 0.0 (centre), angle = (0.0 + 1.0) * pi/4 = pi/4
      // equal-power gains are cos(pi/4) = sin(pi/4) = 1/sqrt(2) ≈ 0.70710678
      // Sum = 2 * (1 / sqrt(2)) = sqrt(2) ≈ 1.41421356
      final p = CrossfadeProcessor(
        numChannels: 1,
        mix: 0.0,
        mode: CrossfadeMode.equalPower,
      );
      p.process(context, [inA, inB], [out]);
      final expected = math.sqrt(2.0);
      for (int i = 0; i < vectorSize; i++) {
        expect(out[i], closeTo(expected, 1e-5));
      }
    });

    test('supports audio-rate signal modulation of mix', () {
      const vectorSize = 4;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      final inA = Float32List.fromList([10, 10, 10, 10]);
      final inB = Float32List.fromList([20, 20, 20, 20]);
      final mixSig = Float32List.fromList([-1.0, -0.5, 0.5, 1.0]);
      final out = Float32List(vectorSize);

      final p = CrossfadeProcessor(
        numChannels: 1,
        mix: null,
        mode: CrossfadeMode.linear,
      );
      p.process(context, [mixSig, inA, inB], [out]);

      expect(out[0], closeTo(10.0, 1e-5));
      expect(out[1], closeTo(12.5, 1e-5));
      expect(out[2], closeTo(17.5, 1e-5));
      expect(out[3], closeTo(20.0, 1e-5));
    });

    test('processes stereo channels simultaneously', () {
      const vectorSize = 4;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      final inALeft = Float32List.fromList([1, 1, 1, 1]);
      final inARight = Float32List.fromList([2, 2, 2, 2]);
      final inBLeft = Float32List.fromList([10, 10, 10, 10]);
      final inBRight = Float32List.fromList([20, 20, 20, 20]);
      final outLeft = Float32List(vectorSize);
      final outRight = Float32List(vectorSize);

      final p = CrossfadeProcessor(
        numChannels: 2,
        mix: 0.0,
        mode: CrossfadeMode.linear,
      );
      p.process(
        context,
        [inALeft, inARight, inBLeft, inBRight],
        [outLeft, outRight],
      );

      for (int i = 0; i < vectorSize; i++) {
        expect(outLeft[i], closeTo(5.5, 1e-5));
        expect(outRight[i], closeTo(11.0, 1e-5));
      }
    });

    test('compiles inside pipeline and updates live parameter', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final oscA = SineOscillator(frequency: const .value(100));
      final oscB = SineOscillator(frequency: const .value(200));

      final crossfade = Crossfade.mono(
        a: oscA.outlet,
        b: oscB.outlet,
        mix: const .value(-1.0),
      );
      final sink = WavSink.memory(channels: [crossfade.outlet]);

      final pipeline = compilePipeline(root: sink, context: context);
      pipeline.process();

      final updatedCrossfade = Crossfade.mono(
        a: oscA.outlet,
        b: oscB.outlet,
        mix: const .value(1.0),
        mode: CrossfadeMode.linear,
      );
      pipeline.update(crossfade, updatedCrossfade);
      pipeline.process();

      final crossProcessor = pipeline.processorOf(crossfade);
      expect(crossProcessor.mix, equals(1.0));
      expect(crossProcessor.mode, equals(CrossfadeMode.linear));

      final wavProcessor = pipeline.processorOf(sink);
      final bytes = wavProcessor.close();
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(44));
    });
  });
}
