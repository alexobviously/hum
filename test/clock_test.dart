import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Clock node', () {
    test('declares expected inlets and outlets', () {
      final clock = Clock(
        frequency: const .value(4.0),
        pulseWidth: const .value(0.25),
      );

      expect(clock.inlets.length, equals(2));
      expect(clock.inlets[Clock.freqInlet].index, equals(Clock.freqInlet));
      expect(
        clock.inlets[Clock.pulseWidthInlet].index,
        equals(Clock.pulseWidthInlet),
      );
      expect(clock.outlets.length, equals(2));
      expect(clock.gate, equals(clock.outlets[Clock.gateOutlet]));
      expect(clock.trigger, equals(clock.outlets[Clock.triggerOutlet]));
    });

    test('Clock.bpm sets frequency correctly', () {
      final clock = Clock.bpm(120);
      expect(clock.frequency.valueOrNull, equals(2.0));

      final fastClock = Clock.bpm(240);
      expect(fastClock.frequency.valueOrNull, equals(4.0));
    });

    test('generates unipolar gate and single-sample trigger impulses', () {
      // 10 Hz at 100 Hz sample rate => 10 samples per cycle
      const sampleRate = 100;
      const vectorSize = 10;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final clock = Clock(
        frequency: const .value(10.0),
        pulseWidth: const .value(0.4), // 4 samples high, 6 samples low
      );
      final processor = clock.createProcessor();

      final gateOut = Float32List(vectorSize);
      final triggerOut = Float32List(vectorSize);
      processor.process(context, [], [gateOut, triggerOut]);

      // Gate: First 4 samples should be 1.0 (phase < 0.4), remaining 6 samples 0.0
      expect(gateOut.sublist(0, 4), equals([1.0, 1.0, 1.0, 1.0]));
      expect(gateOut.sublist(4, 10), equals([0.0, 0.0, 0.0, 0.0, 0.0, 0.0]));

      // Trigger: ONLY sample 0 should be 1.0, remaining 9 samples 0.0
      expect(triggerOut[0], equals(1.0));
      for (int i = 1; i < vectorSize; i++) {
        expect(
          triggerOut[i],
          equals(0.0),
          reason: 'Trigger at index $i should be 0.0',
        );
      }

      // Process second block (cycle 2)
      final gateOut2 = Float32List(vectorSize);
      final triggerOut2 = Float32List(vectorSize);
      processor.process(context, [], [gateOut2, triggerOut2]);

      // Cycle 2 trigger should fire again on sample 0
      expect(triggerOut2[0], equals(1.0));
      for (int i = 1; i < vectorSize; i++) {
        expect(triggerOut2[i], equals(0.0));
      }
    });

    test(
      'can be compiled in AudioPipeline targeting both gate and trigger',
      () {
        final clock = Clock.bpm(120);
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final pipeline = compilePipeline(
          targetOutputs: [clock.gate, clock.trigger],
          context: context,
        );

        pipeline.process();
        expect(pipeline.outputs.length, equals(2));
        expect(pipeline.outputs[0].length, equals(64));
        expect(pipeline.outputs[1].length, equals(64));

        // Gate starts high at phase 0
        expect(pipeline.outputs[0][0], equals(1.0));
        // Trigger impulse on sample 0
        expect(pipeline.outputs[1][0], equals(1.0));
        // Trigger is 0.0 on subsequent samples
        expect(pipeline.outputs[1][1], equals(0.0));
      },
    );
  });
}
