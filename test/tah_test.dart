import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Track & Hold (Tah)', () {
    test('declares expected inlets and outlets for mono, stereo, and multi-channel', () {
      final gate = Clock(frequency: const .value(10));
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SawtoothOscillator(frequency: const .value(880));
      final oscC = TriangleOscillator(frequency: const .value(220));

      final mono = Tah.mono(
        gate: gate.gate,
        input: oscA.outlet,
        threshold: 0.2,
        activeHigh: false,
      );
      expect(mono.inlets.length, equals(2));
      expect(mono.inlets[Tah.gateInlet].source, equals(gate.gate));
      expect(mono.inlets[1].source, equals(oscA.outlet));
      expect(mono.outlets.length, equals(1));
      expect(mono.outlet, equals(mono.outlets.first));
      expect(mono.params.threshold, equals(0.2));
      expect(mono.params.activeHigh, isFalse);

      final stereo = Tah.stereo(
        gate: gate.gate,
        leftInput: oscA.outlet,
        rightInput: oscB.outlet,
      );
      expect(stereo.inlets.length, equals(3));
      expect(stereo.inlets[Tah.gateInlet].source, equals(gate.gate));
      expect(stereo.inlets[1].source, equals(oscA.outlet));
      expect(stereo.inlets[2].source, equals(oscB.outlet));
      expect(stereo.outlets.length, equals(2));

      final multi = Tah(
        gate: gate.gate,
        channels: [oscA.outlet, oscB.outlet, oscC.outlet],
      );
      expect(multi.inlets.length, equals(4));
      expect(multi.outlets.length, equals(3));
    });

    test('tracks live input when gate is high and holds last sample when gate drops', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 8);
      final processor = TahProcessor(
        numChannels: 1,
        threshold: 0.5,
        activeHigh: true,
      );

      // Gate:
      // i=0,1: low (holds initial 0.0)
      // i=2,3,4: high (tracks live input)
      // i=5,6,7: low (holds last sample from i=4)
      final gateBuf = Float32List.fromList([
        0.0,
        0.0,
        1.0,
        1.0,
        1.0,
        0.0,
        0.0,
        0.0,
      ]);
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
        [gateBuf, inBuf],
        [outBuf],
      );

      // i=0,1: held initial 0.0
      expect(outBuf[0], equals(0.0));
      expect(outBuf[1], equals(0.0));

      // i=2,3,4: tracking live input
      expect(outBuf[2], equals(30.0));
      expect(outBuf[3], equals(40.0));
      expect(outBuf[4], equals(50.0));

      // i=5,6,7: frozen at last sample (50.0)
      expect(outBuf[5], equals(50.0));
      expect(outBuf[6], equals(50.0));
      expect(outBuf[7], equals(50.0));
    });

    test('supports inverted activeHigh polarity (tracks when low, holds when high)', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 8);
      final processor = TahProcessor(
        numChannels: 1,
        threshold: 0.5,
        activeHigh: false,
      );

      // Gate:
      // i=0,1: low (<= 0.5) -> tracking
      // i=2,3: high (> 0.5) -> holding last sample from i=1
      // i=4,5,6,7: low (<= 0.5) -> tracking resumed
      final gateBuf = Float32List.fromList([0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0]);
      final inBuf = Float32List.fromList([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]);
      final outBuf = Float32List(8);

      processor.process(
        context,
        [gateBuf, inBuf],
        [outBuf],
      );

      expect(outBuf[0], equals(1.0));
      expect(outBuf[1], equals(2.0));
      // Gate went high: freeze at 2.0
      expect(outBuf[2], equals(2.0));
      expect(outBuf[3], equals(2.0));
      // Gate went low: resumes tracking live input
      expect(outBuf[4], equals(5.0));
      expect(outBuf[5], equals(6.0));
      expect(outBuf[6], equals(7.0));
      expect(outBuf[7], equals(8.0));
    });

    test('retains held value across block boundaries', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = TahProcessor(
        numChannels: 1,
        threshold: 0.5,
        activeHigh: true,
      );

      // Block 1: tracks, ends with 88.0
      final gate1 = Float32List.fromList([1.0, 1.0, 1.0, 1.0]);
      final in1 = Float32List.fromList([55.0, 66.0, 77.0, 88.0]);
      final out1 = Float32List(4);
      processor.process(context, [gate1, in1], [out1]);
      expect(out1, equals([55.0, 66.0, 77.0, 88.0]));

      // Block 2: gate drops to 0.0 for entire block -> continues holding 88.0
      final gate2 = Float32List.fromList([0.0, 0.0, 0.0, 0.0]);
      final in2 = Float32List.fromList([100.0, 200.0, 300.0, 400.0]);
      final out2 = Float32List(4);
      processor.process(context, [gate2, in2], [out2]);
      expect(out2, equals([88.0, 88.0, 88.0, 88.0]));
    });

    test('tracks and holds multi-channel audio independently', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = TahProcessor(
        numChannels: 2,
        threshold: 0.5,
        activeHigh: true,
      );

      // i=0: tracking, i=1,2,3: holding
      final gateBuf = Float32List.fromList([1.0, 0.0, 0.0, 0.0]);
      final leftIn = Float32List.fromList([10.0, 20.0, 30.0, 40.0]);
      final rightIn = Float32List.fromList([100.0, 200.0, 300.0, 400.0]);
      final leftOut = Float32List(4);
      final rightOut = Float32List(4);

      processor.process(
        context,
        [gateBuf, leftIn, rightIn],
        [leftOut, rightOut],
      );

      // Left channel
      expect(leftOut[0], equals(10.0));
      expect(leftOut[1], equals(10.0));
      expect(leftOut[2], equals(10.0));
      expect(leftOut[3], equals(10.0));

      // Right channel
      expect(rightOut[0], equals(100.0));
      expect(rightOut[1], equals(100.0));
      expect(rightOut[2], equals(100.0));
      expect(rightOut[3], equals(100.0));
    });

    test('trackAndHold extension syntax creates Tah node', () {
      final osc = SineOscillator(frequency: const .value(440));
      final gate = Clock(frequency: const .value(4));
      final tah = osc.outlet.tah(
        gate.gate,
        threshold: 0.25,
        activeHigh: false,
      );

      expect(tah, isA<Tah>());
      expect(tah.inlets[Tah.gateInlet].source, equals(gate.gate));
      expect(tah.inlets[1].source, equals(osc.outlet));
      expect(tah.params.threshold, equals(0.25));
      expect(tah.params.activeHigh, isFalse);
    });

    test('compiles inside AudioPipeline and updates live parameters', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final clock = Clock(frequency: const .value(1000));
      final saw = SawtoothOscillator(frequency: const .value(100));
      final tah = Tah.mono(
        gate: clock.gate,
        input: saw.outlet,
        threshold: 0.5,
        activeHigh: true,
      );

      final pipeline = compilePipeline(root: tah, context: context).pipeline!;
      pipeline.process();

      final out1 = pipeline.outputs[0];
      // Should contain audio output
      expect(out1.any((s) => s != 0.0), isTrue);

      // Live update to activeHigh: false
      final updatedTah = Tah.mono(
        gate: clock.gate,
        input: saw.outlet,
        threshold: 0.5,
        activeHigh: false,
      );
      pipeline.update(tah, updatedTah);

      pipeline.process();
      final out2 = pipeline.outputs[0];
      expect(out2.any((s) => s != 0.0), isTrue);
    });
  });
}
