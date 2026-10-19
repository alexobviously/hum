import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Chance node', () {
    test('declares expected inlets and outlets', () {
      final clock = Clock.bpm(120);
      final chance = Chance(
        input: clock.trigger,
        probability: const .value(0.7),
      );

      expect(chance.inlets.length, equals(1));
      expect(chance.inlets[Chance.inputInlet].source, equals(clock.trigger));

      expect(chance.outlets.length, equals(2));
      expect(chance.a, equals(chance.outlets[0]));
      expect(chance.b, equals(chance.outlets[1]));
      expect(chance.pass, equals(chance.a));
      expect(chance.alt, equals(chance.b));
    });

    test('probability 1.0 routes 100% of events to outlet A', () {
      final clock = Clock.bpm(120);
      final chance = Chance(
        input: clock.trigger,
        probability: const .value(1.0),
      );
      final processor = chance.createProcessor();

      const vectorSize = 64;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      final inBuf = Float32List(vectorSize);
      inBuf[10] = 1.0;
      inBuf[30] = 1.0;
      inBuf[50] = 1.0;

      final outA = Float32List(vectorSize);
      final outB = Float32List(vectorSize);

      processor.process(context, [inBuf], [outA, outB]);

      // Outlet A receives all hits
      expect(outA[10], equals(1.0));
      expect(outA[30], equals(1.0));
      expect(outA[50], equals(1.0));

      // Outlet B remains entirely silent
      for (int i = 0; i < vectorSize; i++) {
        expect(outB[i], equals(0.0));
      }
    });

    test('probability 0.0 routes 100% of events to outlet B', () {
      final clock = Clock.bpm(120);
      final chance = Chance(
        input: clock.trigger,
        probability: const .value(0.0),
      );
      final processor = chance.createProcessor();

      const vectorSize = 64;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      final inBuf = Float32List(vectorSize);
      inBuf[10] = 1.0;
      inBuf[30] = 1.0;
      inBuf[50] = 1.0;

      final outA = Float32List(vectorSize);
      final outB = Float32List(vectorSize);

      processor.process(context, [inBuf], [outA, outB]);

      // Outlet A remains entirely silent
      for (int i = 0; i < vectorSize; i++) {
        expect(outA[i], equals(0.0));
      }

      // Outlet B receives all hits
      expect(outB[10], equals(1.0));
      expect(outB[30], equals(1.0));
      expect(outB[50], equals(1.0));
    });

    test(
      'latches routing decision across entire gate duration without chattering',
      () {
        final clock = Clock.bpm(120);
        // Fixed seed 42 to give deterministic routing outcome
        final chance = Chance(
          input: clock.gate,
          probability: const .value(0.5),
          seed: 42,
        );
        final processor = chance.createProcessor();

        const vectorSize = 100;
        final context = ProcessContext(
          sampleRate: 44100,
          vectorSize: vectorSize,
        );

        // Gate held high continuously from sample 10 to 49 (40 samples)
        final inBuf = Float32List(vectorSize);
        for (int i = 10; i < 50; i++) {
          inBuf[i] = 1.0;
        }

        final outA = Float32List(vectorSize);
        final outB = Float32List(vectorSize);

        processor.process(context, [inBuf], [outA, outB]);

        // Check whether it routed to A or B
        final bool routedToA = outA[10] > 0.0;
        final bool routedToB = outB[10] > 0.0;
        expect(
          routedToA ^ routedToB,
          isTrue,
          reason: 'Must route exclusively to either A or B',
        );

        final activeOut = routedToA ? outA : outB;
        final silentOut = routedToA ? outB : outA;

        // Before gate (samples 0..9): both silent
        for (int i = 0; i < 10; i++) {
          expect(activeOut[i], equals(0.0));
          expect(silentOut[i], equals(0.0));
        }

        // During gate (samples 10..49): active outlet stays continuously high!
        for (int i = 10; i < 50; i++) {
          expect(
            activeOut[i],
            equals(1.0),
            reason: 'Active outlet must not chatter or drop mid-gate',
          );
          expect(silentOut[i], equals(0.0));
        }

        // After gate falls low (samples 50..99): both silent
        for (int i = 50; i < vectorSize; i++) {
          expect(activeOut[i], equals(0.0));
          expect(silentOut[i], equals(0.0));
        }
      },
    );

    test('preserves dynamic amplitude / velocity on chosen outlet', () {
      final clock = Clock.bpm(120);
      final chance = Chance(
        input: clock.trigger,
        probability: const .value(1.0),
      );
      final processor = chance.createProcessor();

      const vectorSize = 32;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      final inBuf = Float32List(vectorSize);
      inBuf[5] = 0.85; // Accented hit
      inBuf[15] = 0.35; // Ghost note hit

      final outA = Float32List(vectorSize);
      final outB = Float32List(vectorSize);

      processor.process(context, [inBuf], [outA, outB]);

      expect(outA[5], closeTo(0.85, 0.0001));
      expect(outA[15], closeTo(0.35, 0.0001));
    });

    test('statistically distributes hits according to probability', () {
      const numTrials = 1000;
      final clock = Clock.bpm(120);
      final chance = Chance(
        input: clock.trigger,
        probability: const .value(0.7),
        seed: 12345,
      );
      final processor = chance.createProcessor();

      final context = ProcessContext(sampleRate: 44100, vectorSize: 2);
      int hitsA = 0;
      int hitsB = 0;

      final inBuf = Float32List(2);
      final outA = Float32List(2);
      final outB = Float32List(2);

      for (int i = 0; i < numTrials; i++) {
        inBuf[0] = 1.0; // Trigger rising edge
        inBuf[1] = 0.0; // Reset for next iteration

        processor.process(context, [inBuf], [outA, outB]);

        if (outA[0] > 0.0) hitsA++;
        if (outB[0] > 0.0) hitsB++;
      }

      expect(hitsA + hitsB, equals(numTrials));
      // With 70% probability over 1000 trials, hitsA should be ~700 (within 650..750)
      expect(hitsA, inInclusiveRange(650, 750));
    });

    test(
      'compiles and executes inside AudioPipeline with live parameter updates',
      () {
        final clock = Clock.bpm(120);
        final chance = Chance(
          input: clock.trigger,
          probability: const .value(0.5),
        );

        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final pipeline = compilePipeline(root: chance, context: context);

        pipeline.process();
        expect(pipeline.outputs.length, equals(2));
        expect(pipeline.outputs[0].length, equals(64));
        expect(pipeline.outputs[1].length, equals(64));

        // Update probability to 1.0 on the fly
        pipeline.update(
          chance,
          Chance(input: clock.trigger, probability: const .value(1.0)),
        );
        pipeline.process();
        expect(pipeline.outputs[0].length, equals(64));
      },
    );

    test('Outlet.chance extension method creates Chance node', () {
      final clock = Clock.bpm(120);
      final chance = clock.trigger.chance(0.8, 999);

      expect(chance, isA<Chance>());
      expect(chance.params.probability, equals(0.8));
    });
  });
}
