import 'dart:typed_data';

import 'package:dsp/dsp.dart';
import 'package:test/test.dart';

void main() {
  group('NoiseGenerator node', () {
    test('has expected inlets, outlets, and params', () {
      final white = NoiseGenerator.white(seed: 42);
      expect(white.inlets, isEmpty);
      expect(white.outlets.length, equals(1));
      expect(white.outlet, equals(white.outlets.first));
      expect(white.params.type, equals(NoiseType.white));

      final pink = NoiseGenerator.pink();
      expect(pink.params.type, equals(NoiseType.pink));

      final brown = NoiseGenerator.brown();
      expect(brown.params.type, equals(NoiseType.brown));
    });

    test('supports scale extension', () {
      final noise = NoiseGenerator.pink();
      final scaled = noise.scale(-0.5, 0.5);

      expect(scaled.inlets.first.source, equals(noise.outlet));
    });

    test('reproducible with explicit seed', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);

      final p1 = NoiseGeneratorProcessor(type: NoiseType.white, seed: 12345);
      final p2 = NoiseGeneratorProcessor(type: NoiseType.white, seed: 12345);

      final out1 = Float32List(64);
      final out2 = Float32List(64);

      p1.process(context, [], [out1]);
      p2.process(context, [], [out2]);

      expect(out1, equals(out2));
    });

    test('different seeds produce different sequences', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);

      final p1 = NoiseGeneratorProcessor(type: NoiseType.white, seed: 111);
      final p2 = NoiseGeneratorProcessor(type: NoiseType.white, seed: 222);

      final out1 = Float32List(64);
      final out2 = Float32List(64);

      p1.process(context, [], [out1]);
      p2.process(context, [], [out2]);

      expect(out1, isNot(equals(out2)));
    });

    test('processes in compiled pipeline', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 128);
      final noise = NoiseGenerator.pink(seed: 999);
      final gain = Gain.mono(gain: .value(0.5), input: noise.outlet);
      final pipeline = compilePipeline(root: gain, context: context);

      pipeline.process();
      final output = pipeline.outputs[0];

      expect(output.length, equals(128));
      expect(output.every((s) => s >= -1.0 && s <= 1.0), isTrue);
      expect(output.any((s) => s != 0.0), isTrue);
    });

    test('white, pink, and brown remain bounded over multiple buffers', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 256);

      for (final type in NoiseType.values) {
        final processor = NoiseGeneratorProcessor(type: type, seed: 54321);
        final buffer = Float32List(256);

        for (int block = 0; block < 20; block++) {
          processor.process(context, [], [buffer]);

          expect(
            buffer.every((s) => s >= -1.0 && s <= 1.0),
            isTrue,
            reason: '$type exceeded bounds at block $block',
          );
        }
      }
    });

    test('processor update updates noise type dynamically', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final processor = NoiseGeneratorProcessor(
        type: NoiseType.white,
        seed: 777,
      );

      expect(processor.type, equals(NoiseType.white));

      final outWhite = Float32List(64);
      processor.process(context, [], [outWhite]);

      processor.update((type: NoiseType.brown));
      expect(processor.type, equals(NoiseType.brown));

      final outBrown = Float32List(64);
      processor.process(context, [], [outBrown]);

      expect(outBrown.length, equals(64));
    });
  });
}
