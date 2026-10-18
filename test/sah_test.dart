import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Sample & Hold (Sah)', () {
    test('declares expected inlets and outlets for mono, stereo, and multi-channel', () {
      final trig = SquareOscillator(frequency: const .value(10));
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SawtoothOscillator(frequency: const .value(880));
      final oscC = TriangleOscillator(frequency: const .value(220));

      final mono = Sah.mono(
        trigger: trig.outlet,
        input: oscA.outlet,
        threshold: 0.2,
        triggerEdge: TriggerEdge.falling,
      );
      expect(mono.inlets.length, equals(2));
      expect(mono.inlets[Sah.triggerInlet].source, equals(trig.outlet));
      expect(mono.inlets[1].source, equals(oscA.outlet));
      expect(mono.outlets.length, equals(1));
      expect(mono.outlet, equals(mono.outlets.first));
      expect(mono.params.threshold, equals(0.2));
      expect(mono.params.triggerEdge, equals(TriggerEdge.falling));

      final stereo = Sah.stereo(
        trigger: trig.outlet,
        leftInput: oscA.outlet,
        rightInput: oscB.outlet,
      );
      expect(stereo.inlets.length, equals(3));
      expect(stereo.inlets[Sah.triggerInlet].source, equals(trig.outlet));
      expect(stereo.inlets[1].source, equals(oscA.outlet));
      expect(stereo.inlets[2].source, equals(oscB.outlet));
      expect(stereo.outlets.length, equals(2));

      final multi = Sah(
        trigger: trig.outlet,
        channels: [oscA.outlet, oscB.outlet, oscC.outlet],
      );
      expect(multi.inlets.length, equals(4));
      expect(multi.outlets.length, equals(3));
    });

    test('samples on rising edge and holds value steady', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 8);
      final processor = SahProcessor(
        numChannels: 1,
        threshold: 0.5,
        triggerEdge: TriggerEdge.rising,
      );

      // Trigger: stays 0, rises above 0.5 at index 2, stays high, drops at 5, rises at 6
      final trigBuf = Float32List.fromList([
        0.0,
        0.0,
        1.0,
        1.0,
        1.0,
        0.0,
        1.0,
        1.0,
      ]);
      // Input signal ramp
      final inBuf = Float32List.fromList([
        10.0,
        20.0,
        30.0,
        40.0,
        50.0,
        60.0,
        70.0,
        80.0,
      ]);
      final outBuf = Float32List(8);

      processor.process(
        context,
        [trigBuf, inBuf],
        [outBuf],
      );

      // index 0: initial hold is 0.0
      expect(outBuf[0], equals(0.0));
      // index 1: still 0.0
      expect(outBuf[1], equals(0.0));
      // index 2: rising edge (0.0 -> 1.0 > 0.5), latches 30.0
      expect(outBuf[2], equals(30.0));
      // index 3: trig is 1.0 (prev was 1.0, not rising), holds 30.0
      expect(outBuf[3], equals(30.0));
      // index 4: holds 30.0
      expect(outBuf[4], equals(30.0));
      // index 5: falling edge (1.0 -> 0.0), edge is rising so holds 30.0
      expect(outBuf[5], equals(30.0));
      // index 6: rising edge (0.0 -> 1.0 > 0.5), latches 70.0
      expect(outBuf[6], equals(70.0));
      // index 7: holds 70.0
      expect(outBuf[7], equals(70.0));
    });

    test('samples on falling edge', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 6);
      final processor = SahProcessor(
        numChannels: 1,
        threshold: 0.5,
        triggerEdge: TriggerEdge.falling,
      );

      // Trigger rises at 1, falls below 0.5 at 4
      final trigBuf = Float32List.fromList([0.0, 1.0, 1.0, 1.0, 0.0, 0.0]);
      final inBuf = Float32List.fromList([5.0, 15.0, 25.0, 35.0, 45.0, 55.0]);
      final outBuf = Float32List(6);

      processor.process(
        context,
        [trigBuf, inBuf],
        [outBuf],
      );

      // Rising edge at index 1 is ignored by falling edge trigger
      expect(outBuf[0], equals(0.0));
      expect(outBuf[1], equals(0.0));
      expect(outBuf[2], equals(0.0));
      expect(outBuf[3], equals(0.0));
      // Falling edge at index 4 (1.0 -> 0.0 <= 0.5), latches 45.0
      expect(outBuf[4], equals(45.0));
      expect(outBuf[5], equals(45.0));
    });

    test('samples on both rising and falling edges', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 6);
      final processor = SahProcessor(
        numChannels: 1,
        threshold: 0.0,
        triggerEdge: TriggerEdge.both,
      );

      // Trigger transitions: 0->1 (rising @ 1), 1->-1 (falling @ 3), -1->1 (rising @ 5)
      final trigBuf = Float32List.fromList([-1.0, 1.0, 1.0, -1.0, -1.0, 1.0]);
      final inBuf = Float32List.fromList([
        100.0,
        200.0,
        300.0,
        400.0,
        500.0,
        600.0,
      ]);
      final outBuf = Float32List(6);

      processor.process(
        context,
        [trigBuf, inBuf],
        [outBuf],
      );

      // index 0: initial held (0.0), prevTrigger was 0.0, trig is -1.0 (<= 0.0), no edge
      expect(outBuf[0], equals(0.0));
      // index 1: rising edge (-1.0 -> 1.0 > 0.0), latches 200.0
      expect(outBuf[1], equals(200.0));
      // index 2: high, holds 200.0
      expect(outBuf[2], equals(200.0));
      // index 3: falling edge (1.0 -> -1.0 <= 0.0), latches 400.0
      expect(outBuf[3], equals(400.0));
      // index 4: low, holds 400.0
      expect(outBuf[4], equals(400.0));
      // index 5: rising edge (-1.0 -> 1.0 > 0.0), latches 600.0
      expect(outBuf[5], equals(600.0));
    });

    test('retains trigger state across block boundaries', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 3);
      final processor = SahProcessor(
        numChannels: 1,
        threshold: 0.5,
        triggerEdge: TriggerEdge.rising,
      );

      // Block 1: trigger stays low (0.0)
      final trig1 = Float32List.fromList([0.0, 0.0, 0.0]);
      final in1 = Float32List.fromList([1.0, 2.0, 3.0]);
      final out1 = Float32List(3);
      processor.process(context, [trig1, in1], [out1]);
      expect(out1, equals([0.0, 0.0, 0.0]));

      // Block 2: trigger immediately rises on sample 0 (0.0 -> 1.0)
      final trig2 = Float32List.fromList([1.0, 1.0, 1.0]);
      final in2 = Float32List.fromList([99.0, 100.0, 101.0]);
      final out2 = Float32List(3);
      processor.process(context, [trig2, in2], [out2]);

      // Sample 0 must fire because _prevTrigger was 0.0 from Block 1
      expect(out2[0], equals(99.0));
      expect(out2[1], equals(99.0));
      expect(out2[2], equals(99.0));
    });

    test('samples multi-channel audio independently with shared trigger', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = SahProcessor(
        numChannels: 2,
        threshold: 0.5,
        triggerEdge: TriggerEdge.rising,
      );

      final trigBuf = Float32List.fromList([0.0, 1.0, 1.0, 0.0]);
      final leftIn = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
      final rightIn = Float32List.fromList([10.0, 20.0, 30.0, 40.0]);
      final leftOut = Float32List(4);
      final rightOut = Float32List(4);

      processor.process(
        context,
        [trigBuf, leftIn, rightIn],
        [leftOut, rightOut],
      );

      expect(leftOut[0], equals(0.0));
      expect(rightOut[0], equals(0.0));

      expect(leftOut[1], equals(2.0));
      expect(rightOut[1], equals(20.0));

      expect(leftOut[2], equals(2.0));
      expect(rightOut[2], equals(20.0));

      expect(leftOut[3], equals(2.0));
      expect(rightOut[3], equals(20.0));
    });

    test('sampleAndHold extension syntax creates Sah node', () {
      final osc = SineOscillator(frequency: const .value(440));
      final clock = Clock(frequency: const .value(8));
      final sah = osc.outlet.sah(
        clock.outlet,
        threshold: 0.1,
        triggerEdge: TriggerEdge.both,
      );

      expect(sah, isA<Sah>());
      expect(sah.inlets[Sah.triggerInlet].source, equals(clock.outlet));
      expect(sah.inlets[1].source, equals(osc.outlet));
      expect(sah.params.threshold, equals(0.1));
      expect(sah.params.triggerEdge, equals(TriggerEdge.both));
    });

    test(
      'compiles inside AudioPipeline and responds to live parameter updates',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 128);
        final clock = Clock(
          frequency: const .value(1000),
        ); // triggers every ~44 samples
        final saw = SawtoothOscillator(frequency: const .value(50));
        final sah = Sah.mono(
          trigger: clock.outlet,
          input: saw.outlet,
          threshold: 0.5,
          triggerEdge: TriggerEdge.rising,
        );

        final pipeline = compilePipeline(root: sah, context: context);
        pipeline.process();

        final out1 = pipeline.outputs[0];
        // Output should have non-zero held values (steps)
        expect(out1.any((s) => s != 0.0), isTrue);

        // Verify stepping: consecutive identical values exist due to holding
        int holdCount = 0;
        for (int i = 1; i < 128; i++) {
          if (out1[i] == out1[i - 1] && out1[i] != 0.0) {
            holdCount++;
          }
        }
        expect(holdCount, greaterThan(10));

        // Update parameters live
        final updatedSah = Sah.mono(
          trigger: clock.outlet,
          input: saw.outlet,
          threshold: 0.9,
          triggerEdge: TriggerEdge.falling,
        );
        pipeline.update(sah, updatedSah);

        // Process again with new threshold and edge
        pipeline.process();
        final out2 = pipeline.outputs[0];
        expect(out2.any((s) => s != 0.0), isTrue);
      },
    );
  });
}
