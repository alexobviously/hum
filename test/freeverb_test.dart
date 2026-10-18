import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Freeverb node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final osc = SineOscillator(frequency: const .value(440));
      final monoVerb = Freeverb.mono(input: osc.outlet);

      expect(monoVerb.numInputChannels, equals(1));
      expect(
        monoVerb.inlets.length,
        equals(5),
      ); // roomSize, damp, width, mix, input
      expect(monoVerb.outlets.length, equals(2));
      expect(monoVerb.left, equals(monoVerb.outlets[0]));
      expect(monoVerb.right, equals(monoVerb.outlets[1]));

      final oscL = SineOscillator(frequency: const .value(440));
      final oscR = SineOscillator(frequency: const .value(880));
      final stereoVerb = Freeverb.stereo(left: oscL.outlet, right: oscR.outlet);

      expect(stereoVerb.numInputChannels, equals(2));
      expect(
        stereoVerb.inlets.length,
        equals(6),
      ); // roomSize, damp, width, mix, inL, inR
      expect(stereoVerb.outlets.length, equals(2));
    });

    test('100% dry passes direct signal with zero delay', () {
      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      final dummyOsc = SineOscillator(frequency: const .value(440));
      final verb = Freeverb.mono(
        input: dummyOsc.outlet,
        mix: const .value(-1.0), // 100% dry
      );
      final proc = verb.createProcessor();

      final input = Float32List.fromList([
        0.2,
        0.4,
        0.6,
        0.8,
        -0.2,
        -0.4,
        -0.6,
        -0.8,
      ]);
      final outL = Float32List(vectorSize);
      final outR = Float32List(vectorSize);

      proc.process(context, [input], [outL, outR]);

      for (int i = 0; i < vectorSize; i++) {
        expect(outL[i], closeTo(input[i], 1e-5));
        expect(outR[i], closeTo(input[i], 1e-5));
      }
    });

    test('generates dense reverberation tail and decays stably over time', () {
      const vectorSize = 64;
      const sampleRate = 44100;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final proc = FreeverbProcessor(
        isStereoInput: false,
        roomSize: 0.8,
        damp: 0.3,
        width: 1.0,
        mix: 1.0, // 100% wet
      );

      // Block 0: send an impulse at index 0
      final impulseBuf = Float32List(vectorSize);
      impulseBuf[0] = 1.0;
      final zeroBuf = Float32List(vectorSize);

      final outL = Float32List(vectorSize);
      final outR = Float32List(vectorSize);

      proc.process(context, [impulseBuf], [outL, outR]);

      // At sample 0 with 100% wet, output is 0.0 because shortest comb delay is > 1000 samples
      expect(outL[0], closeTo(0.0, 1e-5));
      expect(outR[0], closeTo(0.0, 1e-5));

      // Process subsequent blocks until the comb delay lines output energy
      // 1116 samples / 64 samples per block ~= 18 blocks
      double peakEnergy = 0.0;
      for (int b = 1; b <= 40; b++) {
        proc.process(context, [zeroBuf], [outL, outR]);
        for (int i = 0; i < vectorSize; i++) {
          final mag = outL[i].abs();
          if (mag > peakEnergy) peakEnergy = mag;
        }
      }

      // Reverb energy must have arrived
      expect(peakEnergy, greaterThan(0.001));

      // Process 200 more blocks (decay tail)
      double lateEnergy = 0.0;
      for (int b = 0; b < 200; b++) {
        proc.process(context, [zeroBuf], [outL, outR]);
      }
      for (int i = 0; i < vectorSize; i++) {
        final mag = outL[i].abs();
        if (mag > lateEnergy) lateEnergy = mag;
      }

      // Energy must have decayed significantly
      expect(lateEnergy, lessThan(peakEnergy));
    });

    test('width parameter controls stereo decorrelation vs mono sum', () {
      const vectorSize = 64;
      const sampleRate = 44100;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Width = 0.0 (Mono reverb)
      final monoProc = FreeverbProcessor(
        isStereoInput: false,
        roomSize: 0.8,
        damp: 0.3,
        width: 0.0, // Mono
        mix: 1.0,
      );

      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0;
      final zeroBuf = Float32List(vectorSize);

      final outL = Float32List(vectorSize);
      final outR = Float32List(vectorSize);

      monoProc.process(context, [inBuf], [outL, outR]);
      for (int b = 0; b < 30; b++) {
        monoProc.process(context, [zeroBuf], [outL, outR]);
      }

      // At width = 0.0, left and right channels must be bit-identical
      for (int i = 0; i < vectorSize; i++) {
        expect(outL[i], closeTo(outR[i], 1e-5));
      }

      // Width = 1.0 (Full stereo)
      final stereoProc = FreeverbProcessor(
        isStereoInput: false,
        roomSize: 0.8,
        damp: 0.3,
        width: 1.0, // Stereo
        mix: 1.0,
      );

      stereoProc.process(context, [inBuf], [outL, outR]);
      for (int b = 0; b < 30; b++) {
        stereoProc.process(context, [zeroBuf], [outL, outR]);
      }

      // At width = 1.0, left and right are decorrelated (different comb lengths)
      bool hasDifference = false;
      for (int i = 0; i < vectorSize; i++) {
        if ((outL[i] - outR[i]).abs() > 1e-4) {
          hasDifference = true;
          break;
        }
      }
      expect(hasDifference, isTrue);
    });

    test('compiles inside AudioPipeline and updates live parameters', () {
      const sampleRate = 44100;
      const vectorSize = 64;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final osc = SineOscillator(frequency: const .value(440));
      final verb = Freeverb.mono(
        input: osc.outlet,
        roomSize: const .value(0.5),
        damp: const .value(0.5),
        width: const .value(1.0),
        mix: const .value(0.0),
      );
      final sink = WavSink.memory(channels: [verb.left, verb.right]);

      final pipeline = compilePipeline(root: sink, context: context);
      pipeline.process();

      // Update parameters live
      final updatedVerb = Freeverb.mono(
        input: osc.outlet,
        roomSize: const .value(0.85),
        damp: const .value(0.2),
        width: const .value(0.7),
        mix: const .value(0.5),
      );
      pipeline.update(verb, updatedVerb);
      pipeline.process();

      final proc = pipeline.processorOf(verb);
      expect(proc.roomSize, equals(0.85));
      expect(proc.damp, equals(0.2));
      expect(proc.width, equals(0.7));
      expect(proc.mix, equals(0.5));

      final bytes = pipeline.processorOf(sink).close();
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(44));
    });
  });
}
