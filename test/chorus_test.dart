import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Chorus node', () {
    test(
      'declares expected inlets and outlets for mono, stereo, and toStereo',
      () {
        final osc = SineOscillator(frequency: const .value(440));

        final monoChorus = Chorus.mono(input: osc.outlet);
        expect(monoChorus.numChannels, equals(1));
        expect(monoChorus.numOutputs, equals(1));
        expect(
          monoChorus.inlets.length,
          equals(6),
        ); // rate, depth, baseDelay, fb, mix, in
        expect(monoChorus.outlets.length, equals(1));
        expect(monoChorus.outlet, equals(monoChorus.outlets.first));

        final oscL = SineOscillator(frequency: const .value(440));
        final oscR = SineOscillator(frequency: const .value(880));
        final stereoChorus = Chorus.stereo(
          leftInput: oscL.outlet,
          rightInput: oscR.outlet,
        );
        expect(stereoChorus.numChannels, equals(2));
        expect(stereoChorus.numOutputs, equals(2));
        expect(stereoChorus.inlets.length, equals(7));
        expect(stereoChorus.outlets.length, equals(2));
        expect(stereoChorus.left, equals(stereoChorus.outlets[0]));
        expect(stereoChorus.right, equals(stereoChorus.outlets[1]));

        final toStereoChorus = Chorus.toStereo(input: osc.outlet);
        expect(toStereoChorus.numChannels, equals(1));
        expect(toStereoChorus.numOutputs, equals(2));
        expect(toStereoChorus.inlets.length, equals(6));
        expect(toStereoChorus.outlets.length, equals(2));
        expect(toStereoChorus.left, equals(toStereoChorus.outlets[0]));
        expect(toStereoChorus.right, equals(toStereoChorus.outlets[1]));
      },
    );

    test('100% dry passes input directly with zero delay', () {
      const sampleRate = 44100;
      const vectorSize = 64;
      final context = const ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final proc = ChorusProcessor(
        numInputs: 1,
        numOutputs: 1,
        mix: 0.0, // 100% dry
      );

      final inBuf = Float32List(vectorSize);
      for (int i = 0; i < vectorSize; i++) {
        inBuf[i] = math.sin(2.0 * math.pi * 440.0 * i / sampleRate);
      }
      final outBuf = Float32List(vectorSize);

      proc.process(context, [inBuf], [outBuf]);

      for (int i = 0; i < vectorSize; i++) {
        expect(outBuf[i], closeTo(inBuf[i], 1e-4));
      }
    });

    test(
      'stereo chorus generates phase-decorrelated left and right outputs',
      () {
        const sampleRate = 44100;
        const vectorSize = 256;
        final context = const ProcessContext(
          sampleRate: sampleRate,
          vectorSize: vectorSize,
        );

        final proc = ChorusProcessor(
          numInputs: 1,
          numOutputs: 2,
          rate: 2.0,
          depth: 0.004,
          baseDelay: 0.015,
          mix: 0.5,
          stereoPhase: math.pi * 0.5, // 90 deg quadrature
        );

        final inBuf = Float32List(vectorSize);
        for (int i = 0; i < vectorSize; i++) {
          inBuf[i] = math.sin(2.0 * math.pi * 220.0 * i / sampleRate);
        }
        final outL = Float32List(vectorSize);
        final outR = Float32List(vectorSize);

        // Process several blocks so delay line fills and LFO sweeps
        for (int b = 0; b < 10; b++) {
          proc.process(context, [inBuf], [outL, outR]);
        }

        // After buffer is primed and LFO is active, left and right channels must diverge
        bool differs = false;
        for (int i = 0; i < vectorSize; i++) {
          if ((outL[i] - outR[i]).abs() > 0.01) {
            differs = true;
            break;
          }
        }
        expect(differs, isTrue);
      },
    );

    test('supports pipeline compilation and outlet extension', () {
      final osc = SawtoothOscillator(frequency: const .value(220));
      final chorus = osc.outlet.chorus(
        rate: const .value(1.5),
        depth: const .value(0.003),
        toStereo: true,
      );

      final pipeline = compilePipeline(
        roots: [chorus],
        context: const ProcessContext(sampleRate: 44100, vectorSize: 64),
      ).pipeline!;
      pipeline.process();
      expect(pipeline.outputs.length, equals(2));
      expect(pipeline.outputs[0].length, equals(64));
      expect(pipeline.outputs[1].length, equals(64));
    });

    test('updates parameters dynamically via update()', () {
      final proc = ChorusProcessor(
        numInputs: 1,
        numOutputs: 1,
        rate: 1.0,
        depth: 0.002,
      );

      proc.update((
        rate: 3.5,
        depth: 0.005,
        baseDelay: 0.020,
        feedback: 0.3,
        mix: 0.7,
        stereoPhase: math.pi,
        maxDelay: 0.05,
      ));

      expect(proc.rate, equals(3.5));
      expect(proc.depth, equals(0.005));
      expect(proc.baseDelay, equals(0.020));
      expect(proc.feedback, equals(0.3));
      expect(proc.mix, equals(0.7));
    });
  });
}
