import 'dart:typed_data';

import 'package:dsp/dsp.dart';
import 'package:test/test.dart';

void main() {
  group('Delay node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final osc = SineOscillator(frequency: const .value(440));
      final monoDelay = Delay.mono(input: osc.outlet);

      expect(monoDelay.numChannels, equals(1));
      expect(monoDelay.inlets.length, equals(5)); // time, feedback, mix, damp, input
      expect(monoDelay.outlets.length, equals(1));
      expect(monoDelay.outlet, equals(monoDelay.outlets.first));

      final oscL = SineOscillator(frequency: const .value(440));
      final oscR = SineOscillator(frequency: const .value(880));
      final stereoDelay = Delay.stereo(
        leftInput: oscL.outlet,
        rightInput: oscR.outlet,
      );

      expect(stereoDelay.numChannels, equals(2));
      expect(stereoDelay.inlets.length, equals(6)); // time, feedback, mix, damp, inL, inR
      expect(stereoDelay.outlets.length, equals(2));
      expect(stereoDelay.left, equals(stereoDelay.outlets[0]));
      expect(stereoDelay.right, equals(stereoDelay.outlets[1]));
    });

    test('delays impulse by exact integer number of samples (100% wet)', () {
      const sampleRate = 1000;
      const vectorSize = 16;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Delay time: 4 samples = 4 / 1000 = 0.004 seconds
      final proc = DelayProcessor(
        numChannels: 1,
        time: 0.004,
        feedback: 0.0,
        mix: 1.0, // 100% wet
      );

      // Feed impulse [1.0, 0.0, 0.0, ...]
      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0;
      final outBuf = Float32List(vectorSize);

      proc.process(context, [inBuf], [outBuf]);

      // With read-then-write delay:
      // index 0: read 4 samples ago -> 0.0
      // index 1: read 4 samples ago -> 0.0
      // index 2: read 4 samples ago -> 0.0
      // index 3: read 4 samples ago -> 0.0
      // index 4: read 4 samples ago (index 0) -> 1.0!
      expect(outBuf[0], equals(0.0));
      expect(outBuf[1], equals(0.0));
      expect(outBuf[2], equals(0.0));
      expect(outBuf[3], equals(0.0));
      expect(outBuf[4], closeTo(1.0, 1e-6));
      expect(outBuf[5], equals(0.0));
    });

    test('performs linear interpolation across fractional delays', () {
      const sampleRate = 1000;
      const vectorSize = 16;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Delay time: 4.5 samples = 4.5 / 1000 = 0.0045 seconds
      final proc = DelayProcessor(
        numChannels: 1,
        time: 0.0045,
        feedback: 0.0,
        mix: 1.0, // 100% wet
      );

      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0;
      final outBuf = Float32List(vectorSize);

      proc.process(context, [inBuf], [outBuf]);

      // At delay 4.5, energy should split equally between sample 4 and sample 5
      expect(outBuf[4], closeTo(0.5, 1e-5));
      expect(outBuf[5], closeTo(0.5, 1e-5));
    });

    test('feedback recirculates decaying echoes', () {
      const sampleRate = 1000;
      const vectorSize = 16;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Delay 4 samples with 0.5 feedback
      final proc = DelayProcessor(
        numChannels: 1,
        time: 0.004,
        feedback: 0.5,
        mix: 1.0,
      );

      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0;
      final outBuf = Float32List(vectorSize);

      proc.process(context, [inBuf], [outBuf]);

      // First echo at sample 4: gain = 1.0
      expect(outBuf[4], closeTo(1.0, 1e-5));
      // Second echo at sample 8: gain = 0.5
      expect(outBuf[8], closeTo(0.5, 1e-5));
      // Third echo at sample 12: gain = 0.25
      expect(outBuf[12], closeTo(0.25, 1e-5));
    });

    test('dry/wet mix controls balance between direct and delayed sound', () {
      const sampleRate = 1000;
      const vectorSize = 8;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Mix = -1.0 (100% dry)
      final procDry = DelayProcessor(
        numChannels: 1,
        time: 0.004,
        feedback: 0.0,
        mix: -1.0,
      );

      final inBuf = Float32List(vectorSize);
      inBuf[0] = 2.0;
      final outDry = Float32List(vectorSize);
      procDry.process(context, [inBuf], [outDry]);

      // Out should have 2.0 at index 0 (dry passthrough) and 0 at index 4 (delayed muted)
      expect(outDry[0], closeTo(2.0, 1e-5));
      expect(outDry[4], equals(0.0));
    });

    test('compiles inside pipeline and responds to live parameter update', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final osc = SineOscillator(frequency: const .value(440));
      final delay = Delay.mono(
        input: osc.outlet,
        time: const .value(0.1),
        feedback: const .value(0.3),
        mix: const .value(0.0),
      );
      final sink = WavSink.memory(channels: [delay.outlet]);

      final pipeline = compilePipeline(root: sink, context: context);
      pipeline.process();

      final updatedDelay = Delay.mono(
        input: osc.outlet,
        time: const .value(0.25),
        feedback: const .value(0.7),
        mix: const .value(0.5),
        damp: const .value(0.6),
      );
      pipeline.update(delay, updatedDelay);
      pipeline.process();

      final proc = pipeline.processorOf(delay);
      expect(proc.time, equals(0.25));
      expect(proc.feedback, equals(0.7));
      expect(proc.mix, equals(0.5));
      expect(proc.damp, equals(0.6));

      final wavProc = pipeline.processorOf(sink);
      final bytes = wavProc.close();
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(44));
    });

    test('damps high frequencies across recirculating feedback echoes', () {
      const sampleRate = 1000;
      const vectorSize = 32;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Delay time: 4 samples (0.004 s), feedback = 0.8, 100% wet
      // Test 1: undamped delay (damp = 0.0)
      final undamped = DelayProcessor(
        numChannels: 1,
        time: 0.004,
        feedback: 0.8,
        mix: 1.0,
        damp: 0.0,
      );

      // Test 2: heavily damped delay (damp = 0.8)
      final damped = DelayProcessor(
        numChannels: 1,
        time: 0.004,
        feedback: 0.8,
        mix: 1.0,
        damp: 0.8,
      );

      // Single sharp impulse at sample 0
      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0;

      final outUndamped = Float32List(vectorSize);
      final outDamped = Float32List(vectorSize);

      undamped.process(context, [inBuf], [outUndamped]);
      damped.process(context, [inBuf], [outDamped]);

      // Echo 1 (sample 4): First arrival has not passed through feedback loop yet,
      // so both undamped and damped produce identical first echo amplitude: 1.0
      expect(outUndamped[4], closeTo(1.0, 1e-4));
      expect(outDamped[4], closeTo(1.0, 1e-4));

      // Echo 2 (sample 8): Recirculated once through the feedback path.
      // In undamped, peak at sample 8 is exactly 1.0 * 0.8 = 0.8.
      expect(outUndamped[8], closeTo(0.8, 1e-4));
      // In damped, 1-pole filter spreads/smooths the sharp impulse energy,
      // so peak amplitude at sample 8 is significantly reduced compared to undamped.
      expect(outDamped[8], lessThan(outUndamped[8]));

      // Echo 3 (sample 12): Recirculated twice through the feedback path.
      expect(outUndamped[12], closeTo(0.64, 1e-4));
      expect(outDamped[12], lessThan(outUndamped[12]));
    });
  });
}
