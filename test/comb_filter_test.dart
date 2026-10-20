import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('CombFilter node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final osc = SineOscillator(frequency: const .value(440));
      final monoComb = CombFilter.mono(input: osc.outlet);

      expect(monoComb.numChannels, equals(1));
      expect(
        monoComb.inlets.length,
        equals(5),
      ); // frequency, feedback, damp, mix, input
      expect(monoComb.outlets.length, equals(1));
      expect(monoComb.outlet, equals(monoComb.outlets.first));

      final oscL = SineOscillator(frequency: const .value(440));
      final oscR = SineOscillator(frequency: const .value(880));
      final stereoComb = CombFilter.stereo(
        leftInput: oscL.outlet,
        rightInput: oscR.outlet,
      );

      expect(stereoComb.numChannels, equals(2));
      expect(
        stereoComb.inlets.length,
        equals(6),
      ); // frequency, feedback, damp, mix, inL, inR
      expect(stereoComb.outlets.length, equals(2));
      expect(stereoComb.left, equals(stereoComb.outlets[0]));
      expect(stereoComb.right, equals(stereoComb.outlets[1]));
    });

    test(
      'recirculates impulse at exact integer harmonic periods (100% wet)',
      () {
        const sampleRate = 1000;
        const vectorSize = 16;
        final context = ProcessContext(
          sampleRate: sampleRate,
          vectorSize: vectorSize,
        );

        // Delay length = 1000 / 250 = 4 samples
        final proc = CombFilterProcessor(
          numChannels: 1,
          frequency: 250.0,
          feedback: 0.5,
          damp: 0.0,
          mix: 1.0, // 100% wet
        );

        final inBuf = Float32List(vectorSize);
        inBuf[0] = 1.0; // single unit impulse
        final outBuf = Float32List(vectorSize);

        proc.process(context, [inBuf], [outBuf]);

        // Sample 0: wet signal is delayed, so 0.0
        expect(outBuf[0], closeTo(0.0, 1e-5));
        // First recirculation at sample 4
        expect(outBuf[4], closeTo(1.0, 1e-4));
        // Second recirculation at sample 8 (feedback = 0.5)
        expect(outBuf[8], closeTo(0.5, 1e-4));
        // Third recirculation at sample 12 (feedback^2 = 0.25)
        expect(outBuf[12], closeTo(0.25, 1e-4));
      },
    );

    test('supports negative feedback for odd harmonics / inverted phase', () {
      const sampleRate = 1000;
      const vectorSize = 16;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Delay length = 1000 / 250 = 4 samples
      final proc = CombFilterProcessor(
        numChannels: 1,
        frequency: 250.0,
        feedback: -0.5, // Negative feedback
        damp: 0.0,
        mix: 1.0,
      );

      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0;
      final outBuf = Float32List(vectorSize);

      proc.process(context, [inBuf], [outBuf]);

      // First echo: +1.0
      expect(outBuf[4], closeTo(1.0, 1e-4));
      // Second echo inverts sign: -0.5
      expect(outBuf[8], closeTo(-0.5, 1e-4));
      // Third echo inverts sign again: +0.25
      expect(outBuf[12], closeTo(0.25, 1e-4));
    });

    test('1-pole feedback damping attenuates high frequency transients', () {
      const sampleRate = 1000;
      const vectorSize = 32;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Undamped comb
      final undamped = CombFilterProcessor(
        numChannels: 1,
        frequency: 250.0,
        feedback: 0.8,
        damp: 0.0,
        mix: 1.0,
      );

      // Damped comb
      final damped = CombFilterProcessor(
        numChannels: 1,
        frequency: 250.0,
        feedback: 0.8,
        damp: 0.7,
        mix: 1.0,
      );

      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0;
      final outUndamped = Float32List(vectorSize);
      final outDamped = Float32List(vectorSize);

      undamped.process(context, [inBuf], [outUndamped]);
      damped.process(context, [inBuf], [outDamped]);

      // At sample 4 (first echo), both produce 1.0 because damping state hasn't acted yet
      expect(outUndamped[4], closeTo(1.0, 1e-3));
      expect(outDamped[4], closeTo(1.0, 1e-3));

      // At sample 8 (second echo), damping filter disperses high frequency spike
      expect(outDamped[8], lessThan(outUndamped[8]));
    });

    test('interpolates sub-sample fractional delays accurately', () {
      const sampleRate = 1000;
      const vectorSize = 16;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Delay length = 1000 / 222.2222 = 4.5 samples (fractional)
      final proc = CombFilterProcessor(
        numChannels: 1,
        frequency: 1000 / 4.5,
        feedback: 0.0, // test single echo
        damp: 0.0,
        mix: 1.0,
      );

      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0;
      final outBuf = Float32List(vectorSize);

      proc.process(context, [inBuf], [outBuf]);

      // With 4.5 delay, sample should split evenly between sample 4 and 5
      expect(outBuf[4], closeTo(0.5, 0.05));
      expect(outBuf[5], closeTo(0.5, 0.05));
    });

    test('respects dry/wet balance', () {
      const sampleRate = 1000;
      const vectorSize = 16;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // 50/50 mix: dry and wet both scaled by equalPowerMix(0.5) = 1/sqrt(2) approx 0.7071
      final proc = CombFilterProcessor(
        numChannels: 1,
        frequency: 250.0,
        feedback: 0.0,
        damp: 0.0,
        mix: 0.5,
      );

      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0;
      final outBuf = Float32List(vectorSize);

      proc.process(context, [inBuf], [outBuf]);

      final expectedGain = 1.0 / math.sqrt(2.0);
      expect(outBuf[0], closeTo(expectedGain, 1e-3)); // direct dry hit
      expect(outBuf[4], closeTo(expectedGain, 1e-3)); // delayed echo hit
    });

    test('supports pipeline compilation and outlet extension', () {
      final osc = SineOscillator(frequency: const .value(220));
      final comb = osc.outlet.comb(
        frequency: const .value(440),
        feedback: const .value(0.7),
        damp: const .value(0.3),
      );

      final pipeline = compilePipeline(
        roots: [comb],
        context: const ProcessContext(sampleRate: 44100, vectorSize: 64),
      );

      pipeline.process();
      expect(pipeline.outputs.length, equals(1));
      expect(pipeline.outputs[0].length, equals(64));
    });

    test('updates parameters dynamically via update()', () {
      final proc = CombFilterProcessor(
        numChannels: 1,
        frequency: 440.0,
        feedback: 0.5,
      );

      proc.update((
        frequency: 880.0,
        feedback: 0.95,
        damp: 0.2,
        mix: 0.8,
        minFrequency: 20.0,
      ));

      expect(proc.frequency, equals(880.0));
      expect(proc.feedback, equals(0.95));
      expect(proc.damp, equals(0.2));
      expect(proc.mix, equals(0.8));
    });
  });
}
