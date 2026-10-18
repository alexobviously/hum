import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Bitcrusher node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final mono = Bitcrusher.mono(input: oscA.outlet);
      expect(mono.numChannels, equals(1));
      expect(
        mono.inlets.length,
        equals(4),
      ); // bitDepth, downsample, mix, audio[0]
      expect(
        mono.inlets[Bitcrusher.bitDepthInlet].index,
        equals(Bitcrusher.bitDepthInlet),
      );
      expect(
        mono.inlets[Bitcrusher.downsampleInlet].index,
        equals(Bitcrusher.downsampleInlet),
      );
      expect(
        mono.inlets[Bitcrusher.mixInlet].index,
        equals(Bitcrusher.mixInlet),
      );
      expect(
        mono.inlets[Bitcrusher.audioInletOffset].source,
        equals(oscA.outlet),
      );
      expect(mono.outlets.length, equals(1));
      expect(mono.outlet, equals(mono.outlets.first));

      final stereo = Bitcrusher.stereo(left: oscA.outlet, right: oscB.outlet);
      expect(stereo.numChannels, equals(2));
      expect(
        stereo.inlets.length,
        equals(5),
      ); // bitDepth, downsample, mix, audioL, audioR
      expect(stereo.outlets.length, equals(2));
      expect(stereo.left, equals(stereo.outlets[0]));
      expect(stereo.right, equals(stereo.outlets[1]));
    });

    test('quantizes continuous signal to discrete bit levels', () {
      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      final dummyOsc = SineOscillator(frequency: const .value(440));

      // 2-bit quantization: 2^(2-1) = 2 levels per side -> values are stepped to -1.0, -0.5, 0.0, 0.5, 1.0
      final crusher = Bitcrusher.mono(
        input: dummyOsc.outlet,
        bitDepth: const .value(2.0),
        downsample: const .value(1.0),
        mix: const .value(1.0), // 100% wet
      );
      final processor = crusher.createProcessor();

      // Linear ramp: 0.0, 0.14, 0.28, 0.42, 0.57, 0.71, 0.85, 1.0
      final input = Float32List.fromList([
        0.0,
        0.14,
        0.28,
        0.42,
        0.57,
        0.71,
        0.85,
        1.0,
      ]);
      final output = [Float32List(vectorSize)];

      processor.process(context, [input], output);

      // Verify each sample is quantized to steps of 0.5 (0.0, 0.5, 1.0)
      for (final s in output[0]) {
        final remainder = (s * 2.0).roundToDouble() - (s * 2.0);
        expect(remainder.abs(), closeTo(0.0, 1e-4));
      }

      // Check specific steps
      expect(output[0][0], equals(0.0));
      expect(output[0][1], equals(0.0)); // 0.14 rounds to 0.0
      expect(output[0][2], equals(0.5)); // 0.28 rounds to 0.5
      expect(output[0][3], equals(0.5)); // 0.42 rounds to 0.5
      expect(output[0][4], equals(0.5)); // 0.57 rounds to 0.5
      expect(output[0][5], equals(0.5)); // 0.71 rounds to 0.5
      expect(output[0][6], equals(1.0)); // 0.85 rounds to 1.0
      expect(output[0][7], equals(1.0)); // 1.0 stays 1.0
    });

    test('performs sample-and-hold downsampling', () {
      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      final dummyOsc = SineOscillator(frequency: const .value(440));

      // Downsample by 4 (sample-and-hold holds for 4 samples) with no bit crushing (16-bit)
      final crusher = Bitcrusher.mono(
        input: dummyOsc.outlet,
        bitDepth: const .value(16.0),
        downsample: const .value(4.0),
        mix: const .value(1.0),
      );
      final processor = crusher.createProcessor();

      final input = Float32List.fromList([
        0.1,
        0.2,
        0.3,
        0.4,
        0.5,
        0.6,
        0.7,
        0.8,
      ]);
      final output = [Float32List(vectorSize)];

      processor.process(context, [input], output);

      // Samples 0..3 should all hold input[0] (0.1)
      expect(output[0][0], closeTo(0.1, 1e-5));
      expect(output[0][1], closeTo(0.1, 1e-5));
      expect(output[0][2], closeTo(0.1, 1e-5));
      expect(output[0][3], closeTo(0.1, 1e-5));

      // Samples 4..7 should all hold input[4] (0.5)
      expect(output[0][4], closeTo(0.5, 1e-5));
      expect(output[0][5], closeTo(0.5, 1e-5));
      expect(output[0][6], closeTo(0.5, 1e-5));
      expect(output[0][7], closeTo(0.5, 1e-5));
    });

    test('respects dry/wet mix balance', () {
      const vectorSize = 4;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      final dummyOsc = SineOscillator(frequency: const .value(440));
      final input = Float32List.fromList([0.3, 0.7, -0.4, -0.8]);

      // 100% Dry (mix = 0.0)
      final dryCrusher = Bitcrusher.mono(
        input: dummyOsc.outlet,
        bitDepth: const .value(2.0),
        mix: const .value(0.0),
      );
      final dryProc = dryCrusher.createProcessor();
      final dryOut = [Float32List(vectorSize)];
      dryProc.process(context, [input], dryOut);

      for (int i = 0; i < vectorSize; i++) {
        expect(dryOut[0][i], closeTo(input[i], 1e-5));
      }

      // 50/50 Mix (mix = 0.5)
      final midCrusher = Bitcrusher.mono(
        input: dummyOsc.outlet,
        bitDepth: const .value(2.0),
        mix: const .value(0.5),
      );
      final midProc = midCrusher.createProcessor();
      final midOut = [Float32List(vectorSize)];
      midProc.process(context, [input], midOut);

      // input[0] = 0.3 -> wet = 0.5. mid = 0.3 * 0.5 + 0.5 * 0.5 = 0.4
      expect(midOut[0][0], closeTo(0.4, 0.01));
    });

    test('compiles inside AudioPipeline and updates live parameters', () {
      final osc = SineOscillator(frequency: const .value(440));
      final crusher = Bitcrusher.mono(
        input: osc.outlet,
        bitDepth: const .value(4.0),
        downsample: const .value(2.0),
      );

      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final pipeline = compilePipeline(root: crusher, context: context);

      pipeline.process();
      expect(pipeline.outputs.length, equals(1));
      expect(pipeline.outputs[0].length, equals(64));

      // Live update to 2-bit
      pipeline.update(
        crusher,
        Bitcrusher.mono(input: osc.outlet, bitDepth: const .value(2.0)),
      );
      final proc = pipeline.processorOf(crusher);
      expect(proc.bitDepth, equals(2.0));
    });
  });
}
