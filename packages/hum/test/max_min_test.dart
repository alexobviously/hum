import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Max and Min nodes', () {
    test(
      'declares expected inlets and outlets for pair, of, mono, and stereo',
      () {
        final oscA = SineOscillator(frequency: const .value(220));
        final oscB = SineOscillator(frequency: const .value(440));
        final oscC = SineOscillator(frequency: const .value(880));

        // Max.pair
        final maxPair = Max.pair(oscA.outlet, oscB.outlet);
        expect(maxPair.inlets.length, equals(2));
        expect(maxPair.outlets.length, equals(1));
        expect(maxPair.outlet, equals(maxPair.outlets.first));

        // Max.of (3 inputs)
        final maxOf = Max.of([oscA.outlet, oscB.outlet, oscC.outlet]);
        expect(maxOf.inlets.length, equals(3));
        expect(maxOf.outlets.length, equals(1));

        // Max.mono (value inlet + 1 audio inlet)
        final maxMono = Max.mono(oscA.outlet, const .value(0.0));
        expect(maxMono.inlets.length, equals(2)); // value, in0
        expect(maxMono.outlets.length, equals(1));

        // Max.stereo (value inlet + 2 audio inlets)
        final maxStereo = Max.stereo(
          oscA.outlet,
          oscB.outlet,
          const .value(0.0),
        );
        expect(maxStereo.inlets.length, equals(3)); // value, left, right
        expect(maxStereo.outlets.length, equals(2));
        expect(maxStereo.left, equals(maxStereo.outlets[0]));
        expect(maxStereo.right, equals(maxStereo.outlets[1]));

        // Min.pair
        final minPair = Min.pair(oscA.outlet, oscB.outlet);
        expect(minPair.inlets.length, equals(2));
        expect(minPair.outlets.length, equals(1));
      },
    );

    test('Max.pair computes sample-by-sample maximum of two signals', () {
      const vs = 4;
      final context = const ProcessContext(sampleRate: 44100, vectorSize: vs);

      final proc = MaxProcessor(
        value: null,
        hasValue: false,
        numChannels: 2,
      );

      final inA = Float32List.fromList([1.0, -0.5, 0.2, -0.8]);
      final inB = Float32List.fromList([0.5, 0.0, 0.8, -1.0]);
      final out = Float32List(vs);

      proc.process(context, [inA, inB], [out]);

      expect(out[0], closeTo(1.0, 1e-5)); // max(1.0, 0.5)
      expect(out[1], closeTo(0.0, 1e-5)); // max(-0.5, 0.0)
      expect(out[2], closeTo(0.8, 1e-5)); // max(0.2, 0.8)
      expect(out[3], closeTo(-0.8, 1e-5)); // max(-0.8, -1.0)
    });

    test('Min.pair computes sample-by-sample minimum of two signals', () {
      const vs = 4;
      final context = const ProcessContext(sampleRate: 44100, vectorSize: vs);

      final proc = MinProcessor(
        value: null,
        hasValue: false,
        numChannels: 2,
      );

      final inA = Float32List.fromList([1.0, -0.5, 0.2, -0.8]);
      final inB = Float32List.fromList([0.5, 0.0, 0.8, -1.0]);
      final out = Float32List(vs);

      proc.process(context, [inA, inB], [out]);

      expect(out[0], closeTo(0.5, 1e-5)); // min(1.0, 0.5)
      expect(out[1], closeTo(-0.5, 1e-5)); // min(-0.5, 0.0)
      expect(out[2], closeTo(0.2, 1e-5)); // min(0.2, 0.8)
      expect(out[3], closeTo(-1.0, 1e-5)); // min(-0.8, -1.0)
    });

    test('Max.of and Min.of compute extreme across 3 or more signals', () {
      const vs = 4;
      final context = const ProcessContext(sampleRate: 44100, vectorSize: vs);

      final maxProc = MaxProcessor(
        value: null,
        hasValue: false,
        numChannels: 3,
      );
      final minProc = MinProcessor(
        value: null,
        hasValue: false,
        numChannels: 3,
      );

      final inA = Float32List.fromList([0.1, 0.9, -0.5, 0.2]);
      final inB = Float32List.fromList([0.8, 0.2, -0.2, -0.1]);
      final inC = Float32List.fromList([0.4, 0.5, -0.9, 0.7]);

      final outMax = Float32List(vs);
      final outMin = Float32List(vs);

      maxProc.process(context, [inA, inB, inC], [outMax]);
      minProc.process(context, [inA, inB, inC], [outMin]);

      expect(outMax[0], closeTo(0.8, 1e-5)); // max(0.1, 0.8, 0.4)
      expect(outMax[1], closeTo(0.9, 1e-5)); // max(0.9, 0.2, 0.5)
      expect(outMax[2], closeTo(-0.2, 1e-5)); // max(-0.5, -0.2, -0.9)
      expect(outMax[3], closeTo(0.7, 1e-5)); // max(0.2, -0.1, 0.7)

      expect(outMin[0], closeTo(0.1, 1e-5)); // min(0.1, 0.8, 0.4)
      expect(outMin[1], closeTo(0.2, 1e-5)); // min(0.9, 0.2, 0.5)
      expect(outMin[2], closeTo(-0.9, 1e-5)); // min(-0.5, -0.2, -0.9)
      expect(outMin[3], closeTo(-0.1, 1e-5)); // min(0.2, -0.1, 0.7)
    });

    test(
      'Max.mono and Min.mono with scalar values clip as half-wave rectifiers',
      () {
        const vs = 4;
        final context = const ProcessContext(sampleRate: 44100, vectorSize: vs);

        // Max with 0.0 -> positive half-wave rectifier
        final maxProc = MaxProcessor(
          value: 0.0,
          hasValue: true,
          numChannels: 1,
        );
        // Min with 0.0 -> negative half-wave rectifier
        final minProc = MinProcessor(
          value: 0.0,
          hasValue: true,
          numChannels: 1,
        );

        final inAudio = Float32List.fromList([0.7, -0.4, 0.0, -0.9]);
        final outMax = Float32List(vs);
        final outMin = Float32List(vs);

        maxProc.process(context, [Float32List(0), inAudio], [outMax]);
        minProc.process(context, [Float32List(0), inAudio], [outMin]);

        expect(outMax[0], closeTo(0.7, 1e-5));
        expect(
          outMax[1],
          closeTo(0.0, 1e-5),
        ); // negative excursion clamped to 0.0
        expect(outMax[3], closeTo(0.0, 1e-5));

        expect(
          outMin[0],
          closeTo(0.0, 1e-5),
        ); // positive excursion clamped to 0.0
        expect(outMin[1], closeTo(-0.4, 1e-5));
        expect(outMin[3], closeTo(-0.9, 1e-5));
      },
    );

    test('Max and Min support signal-modulated value comparison', () {
      const vs = 4;
      final context = const ProcessContext(sampleRate: 44100, vectorSize: vs);

      final proc = MaxProcessor(
        value: null,
        hasValue: true,
        numChannels: 1,
      );

      final valBuffer = Float32List.fromList([
        0.2,
        0.5,
        -0.1,
        0.0,
      ]); // threshold signal
      final audioBuffer = Float32List.fromList([0.1, 0.8, -0.3, 0.4]);
      final out = Float32List(vs);

      proc.process(context, [valBuffer, audioBuffer], [out]);

      expect(out[0], closeTo(0.2, 1e-5)); // max(0.1, 0.2)
      expect(out[1], closeTo(0.8, 1e-5)); // max(0.8, 0.5)
      expect(out[2], closeTo(-0.1, 1e-5)); // max(-0.3, -0.1)
      expect(out[3], closeTo(0.4, 1e-5)); // max(0.4, 0.0)
    });

    test('Outlet and List<Outlet> extension methods work seamlessly', () {
      final oscA = SineOscillator(frequency: const .value(220));
      final oscB = SineOscillator(frequency: const .value(440));
      final oscC = SineOscillator(frequency: const .value(880));

      // Binary .max() / .min() with Outlet
      final maxOut = oscA.outlet.max(oscB.outlet);
      expect(maxOut, isA<Outlet>());

      final minOut = oscA.outlet.min(oscB.outlet);
      expect(minOut, isA<Outlet>());

      // Scalar .max() / .min() with num
      final rectified = oscA.outlet.max(0.0);
      expect(rectified, isA<Outlet>());

      final ceilClamped = oscA.outlet.min(0.5);
      expect(ceilClamped, isA<Outlet>());

      // List .max and .min
      final listMax = [oscA.outlet, oscB.outlet, oscC.outlet].max;
      expect(listMax, isA<Max>());

      final listMin = [oscA.outlet, oscB.outlet, oscC.outlet].min;
      expect(listMin, isA<Min>());
    });

    test('compiles and executes inside AudioPipeline', () {
      final oscA = SineOscillator(frequency: const .value(220));
      final oscB = SineOscillator(frequency: const .value(440));

      final maxNode = oscA.outlet.max(oscB.outlet);

      final pipeline = compilePipeline(
        roots: [maxNode.node],
        context: const ProcessContext(sampleRate: 44100, vectorSize: 64),
      ).pipeline!;
      pipeline.process();
      expect(pipeline.outputs.length, equals(1));
      expect(pipeline.outputs[0].length, equals(64));
    });
  });
}
