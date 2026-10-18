import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Slew / Portamento / Lag', () {
    test('declares expected inlets and outlets for mono, stereo, and multi-channel', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SawtoothOscillator(frequency: const .value(880));
      final oscC = TriangleOscillator(frequency: const .value(220));

      final mono = Slew.mono(
        input: oscA.outlet,
        rise: const .value(0.05),
        fall: const .value(0.10),
      );
      expect(mono.inlets.length, equals(3));
      expect(mono.inlets[Slew.riseInlet].source, equals(null));
      expect(mono.inlets[Slew.fallInlet].source, equals(null));
      expect(mono.inlets[Slew.audioInletOffset].source, equals(oscA.outlet));
      expect(mono.outlets.length, equals(1));
      expect(mono.outlet, equals(mono.outlets.first));
      expect(mono.params.rise, equals(0.05));
      expect(mono.params.fall, equals(0.10));

      final stereo = Slew.stereo(
        leftInput: oscA.outlet,
        rightInput: oscB.outlet,
        time: const .value(0.02),
      );
      expect(stereo.inlets.length, equals(4));
      expect(stereo.inlets[Slew.audioInletOffset].source, equals(oscA.outlet));
      expect(
        stereo.inlets[Slew.audioInletOffset + 1].source,
        equals(oscB.outlet),
      );
      expect(stereo.outlets.length, equals(2));
      expect(stereo.left, equals(stereo.outlets[0]));
      expect(stereo.right, equals(stereo.outlets[1]));
      expect(stereo.params.rise, equals(0.02));
      expect(stereo.params.fall, equals(0.02));

      final multi = Slew(
        channels: [oscA.outlet, oscB.outlet, oscC.outlet],
        rise: const .value(0.01),
        fall: const .value(0.03),
      );
      expect(multi.inlets.length, equals(5));
      expect(multi.outlets.length, equals(3));
    });

    test('convenience constructor Slew.samples calculates time correctly', () {
      final osc = SineOscillator(frequency: const .value(440));
      final slew = Slew.samples(
        channels: [osc.outlet],
        riseSamples: 100,
        fallSamples: 200,
        sampleRate: 1000,
      );
      expect(slew.params.rise, closeTo(0.1, 1e-6));
      expect(slew.params.fall, closeTo(0.2, 1e-6));
    });

    test('instantaneous passthrough when rise and fall are 0.0', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = SlewProcessor(numChannels: 1, rise: 0.0, fall: 0.0);

      final inBuf = Float32List.fromList([0.0, 1.0, -0.5, 0.75]);
      final outBuf = Float32List(4);

      processor.process(context, [inBuf], [outBuf]);

      for (int i = 0; i < 4; i++) {
        expect(outBuf[i], closeTo(inBuf[i], 1e-6));
      }
    });

    test('limits linear rise rate correctly', () {
      // sampleRate: 100 Hz, rise: 1.0 s -> maxRise = 1.0 / (1.0 * 100) = 0.01 per sample
      final context = ProcessContext(sampleRate: 100, vectorSize: 5);
      final processor = SlewProcessor(numChannels: 1, rise: 1.0, fall: 0.0);

      // Input step jump to 1.0
      final inBuf = Float32List.fromList([1.0, 1.0, 1.0, 1.0, 1.0]);
      final outBuf = Float32List(5);

      processor.process(context, [inBuf], [outBuf]);

      expect(outBuf[0], closeTo(0.01, 1e-6));
      expect(outBuf[1], closeTo(0.02, 1e-6));
      expect(outBuf[2], closeTo(0.03, 1e-6));
      expect(outBuf[3], closeTo(0.04, 1e-6));
      expect(outBuf[4], closeTo(0.05, 1e-6));
    });

    test('limits linear fall rate correctly', () {
      // sampleRate: 100 Hz, fall: 0.5 s -> maxFall = 1.0 / (0.5 * 100) = 0.02 per sample
      final context = ProcessContext(sampleRate: 100, vectorSize: 5);
      final processor = SlewProcessor(numChannels: 1, rise: 0.0, fall: 0.5);

      // Start by jumping to 1.0 with no rise limiting
      final stepUp = Float32List.fromList([1.0]);
      final stepUpOut = Float32List(1);
      processor.process(
        ProcessContext(sampleRate: 100, vectorSize: 1),
        [stepUp],
        [stepUpOut],
      );
      expect(stepUpOut[0], closeTo(1.0, 1e-6));

      // Now fall to 0.0 with fall limiting
      final inBuf = Float32List.fromList([0.0, 0.0, 0.0, 0.0, 0.0]);
      final outBuf = Float32List(5);

      processor.process(context, [inBuf], [outBuf]);

      expect(outBuf[0], closeTo(0.98, 1e-6));
      expect(outBuf[1], closeTo(0.96, 1e-6));
      expect(outBuf[2], closeTo(0.94, 1e-6));
      expect(outBuf[3], closeTo(0.92, 1e-6));
      expect(outBuf[4], closeTo(0.90, 1e-6));
    });

    test('handles asymmetric rise and fall times', () {
      // sampleRate: 100 Hz, rise: 0.5 s (0.02/sample), fall: 1.0 s (0.01/sample)
      final context = ProcessContext(sampleRate: 100, vectorSize: 6);
      final processor = SlewProcessor(numChannels: 1, rise: 0.5, fall: 1.0);

      final inBuf = Float32List.fromList([1.0, 1.0, 1.0, -1.0, -1.0, -1.0]);
      final outBuf = Float32List(6);

      processor.process(context, [inBuf], [outBuf]);

      // Rising by 0.02
      expect(outBuf[0], closeTo(0.02, 1e-6));
      expect(outBuf[1], closeTo(0.04, 1e-6));
      expect(outBuf[2], closeTo(0.06, 1e-6));
      // Falling by 0.01 from 0.06 towards -1.0
      expect(outBuf[3], closeTo(0.05, 1e-6));
      expect(outBuf[4], closeTo(0.04, 1e-6));
      expect(outBuf[5], closeTo(0.03, 1e-6));
    });

    test('preserves state across block boundaries', () {
      final context = ProcessContext(sampleRate: 100, vectorSize: 2);
      final processor = SlewProcessor(numChannels: 1, rise: 1.0, fall: 1.0);

      final block1In = Float32List.fromList([1.0, 1.0]);
      final block1Out = Float32List(2);
      processor.process(context, [block1In], [block1Out]);

      expect(block1Out[0], closeTo(0.01, 1e-6));
      expect(block1Out[1], closeTo(0.02, 1e-6));

      final block2In = Float32List.fromList([1.0, 1.0]);
      final block2Out = Float32List(2);
      processor.process(context, [block2In], [block2Out]);

      expect(block2Out[0], closeTo(0.03, 1e-6));
      expect(block2Out[1], closeTo(0.04, 1e-6));
    });

    test('processes multiple channels independently', () {
      final context = ProcessContext(sampleRate: 100, vectorSize: 3);
      final processor = SlewProcessor(numChannels: 2, rise: 1.0, fall: 1.0);

      final leftIn = Float32List.fromList([1.0, 1.0, 1.0]);
      final rightIn = Float32List.fromList([-1.0, -1.0, -1.0]);
      final leftOut = Float32List(3);
      final rightOut = Float32List(3);

      processor.process(context, [leftIn, rightIn], [leftOut, rightOut]);

      expect(leftOut[0], closeTo(0.01, 1e-6));
      expect(leftOut[1], closeTo(0.02, 1e-6));
      expect(leftOut[2], closeTo(0.03, 1e-6));

      expect(rightOut[0], closeTo(-0.01, 1e-6));
      expect(rightOut[1], closeTo(-0.02, 1e-6));
      expect(rightOut[2], closeTo(-0.03, 1e-6));
    });

    test('supports audio-rate modulation of slew rates', () {
      final context = ProcessContext(sampleRate: 100, vectorSize: 3);
      // null static rise/fall indicates control by audio inlets
      final processor = SlewProcessor(numChannels: 1, rise: null, fall: null);

      // riseBuf specifies time in seconds per sample:
      // sample 0: 1.0 s -> maxRise = 0.01
      // sample 1: 0.5 s -> maxRise = 0.02
      // sample 2: 0.25 s -> maxRise = 0.04
      final riseBuf = Float32List.fromList([1.0, 0.5, 0.25]);
      final fallBuf = Float32List.fromList([0.0, 0.0, 0.0]);
      final audioIn = Float32List.fromList([10.0, 10.0, 10.0]);
      final outBuf = Float32List(3);

      processor.process(
        context,
        [riseBuf, fallBuf, audioIn],
        [outBuf],
      );

      expect(outBuf[0], closeTo(0.01, 1e-6));
      expect(outBuf[1], closeTo(0.03, 1e-6)); // 0.01 + 0.02
      expect(outBuf[2], closeTo(0.07, 1e-6)); // 0.03 + 0.04
    });

    test('AudioPipeline correctly processes signal-modulated slew', () {
      final osc = SawtoothOscillator(
        frequency: const .value(100),
        usePolyBlep: false,
      );
      // Modulator that outputs a constant 0.02s slew time
      final mod = Mult.mono(value: const .value(0.02), input: osc.outlet);
      final slew = Slew.mono(
        input: osc.outlet,
        time: .signal(mod.outlet),
      );

      final pipeline = compilePipeline(
        root: slew,
        context: ProcessContext(sampleRate: 44100, vectorSize: 64),
      );

      pipeline.process();
      expect(pipeline.outputs[0].length, equals(64));
      expect(pipeline.outputs[0].any((s) => s != 0.0), isTrue);
    });

    test('compiles and runs in an AudioPipeline with live updates', () {
      final osc = SineOscillator(frequency: const .value(100));
      final slew = Slew.mono(input: osc.outlet, time: const .value(0.5));
      final pipeline = compilePipeline(
        root: slew,
        context: ProcessContext(sampleRate: 44100, vectorSize: 64),
      );

      pipeline.process();
      expect(pipeline.outputs[0].length, equals(64));

      // Test live update
      final updatedSlew = Slew.mono(
        input: osc.outlet,
        rise: const .value(0.1),
        fall: const .value(0.2),
      );
      pipeline.update(slew, updatedSlew);
      final processor = pipeline.processorOf(slew);
      expect(processor.rise, equals(0.1));
      expect(processor.fall, equals(0.2));
    });

    test('outlet extensions slew() and portamento() work as expected', () {
      final osc = SineOscillator(frequency: const .value(100));
      final slewNode = osc.outlet.slew(0.03);
      expect(slewNode.params.rise, equals(0.03));
      expect(slewNode.params.fall, equals(0.03));

      final portNode = osc.outlet.portamento(0.04);
      expect(portNode.params.rise, equals(0.04));
      expect(portNode.params.fall, equals(0.04));
    });
  });
}
