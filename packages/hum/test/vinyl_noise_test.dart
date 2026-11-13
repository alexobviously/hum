import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

List<Float32List> _inlets({
  Float32List? crackle,
  Float32List? hiss,
  Float32List? warp,
  Float32List? density,
  int vectorSize = 128,
}) => [
  crackle ?? Float32List(vectorSize),
  hiss ?? Float32List(vectorSize),
  warp ?? Float32List(vectorSize),
  density ?? Float32List(vectorSize),
];

void main() {
  group('VinylNoise node', () {
    test('declares expected inlets, outlets, and params', () {
      final vinyl = VinylNoise(
        crackle: const .value(0.4),
        hiss: const .value(0.2),
        warp: const .value(0.3),
        density: const .value(30.0),
        rpm: 45.0,
      );

      expect(vinyl.inlets.length, equals(4));
      expect(vinyl.outlets.length, equals(2));
      expect(vinyl.left, equals(vinyl.outlets[0]));
      expect(vinyl.right, equals(vinyl.outlets[1]));
      expect(vinyl.outlet, equals(vinyl.left));

      expect(vinyl.params.crackle, equals(0.4));
      expect(vinyl.params.hiss, equals(0.2));
      expect(vinyl.params.warp, equals(0.3));
      expect(vinyl.params.density, equals(30.0));
      expect(vinyl.params.rpm, equals(45.0));
      expect(vinyl.errors, isEmpty);
    });

    test('named constructors configure rpm correctly', () {
      const vinyl33 = VinylNoise.rpm33();
      const vinyl45 = VinylNoise.rpm45();
      const vinyl78 = VinylNoise.rpm78();

      expect(vinyl33.params.rpm, closeTo(33.333333, 1e-4));
      expect(vinyl45.params.rpm, equals(45.0));
      expect(vinyl78.params.rpm, equals(78.26));
    });

    test('validates parameter bounds', () {
      final invalidCrackle = VinylNoise(crackle: const .value(-0.1));
      expect(invalidCrackle.errors.length, equals(1));
      expect(
        (invalidCrackle.errors.first as AudioNodeParamError).param,
        equals('crackle'),
      );

      final invalidHiss = VinylNoise(hiss: const .value(-0.5));
      expect(invalidHiss.errors.length, equals(1));
      expect(
        (invalidHiss.errors.first as AudioNodeParamError).param,
        equals('hiss'),
      );

      final invalidWarp = VinylNoise(warp: const .value(1.5));
      expect(invalidWarp.errors.length, equals(1));
      expect(
        (invalidWarp.errors.first as AudioNodeParamError).param,
        equals('warp'),
      );

      final invalidDensity = VinylNoise(density: const .value(-5.0));
      expect(invalidDensity.errors.length, equals(1));
      expect(
        (invalidDensity.errors.first as AudioNodeParamError).param,
        equals('density'),
      );

      final invalidRpm = VinylNoise(rpm: 0.0);
      expect(invalidRpm.errors.length, equals(1));
      expect(
        (invalidRpm.errors.first as AudioNodeParamError).param,
        equals('rpm'),
      );
    });
  });

  group('VinylNoiseProcessor', () {
    test('produces non-silent stereo audio with default parameters', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 512);
      final processor = VinylNoiseProcessor(seed: 42);

      final outL = Float32List(512);
      final outR = Float32List(512);

      processor.process(context, _inlets(vectorSize: 512), [outL, outR]);

      final energyL = outL.fold(0.0, (acc, s) => acc + s.abs());
      final energyR = outR.fold(0.0, (acc, s) => acc + s.abs());

      expect(energyL, greaterThan(0.0));
      expect(energyR, greaterThan(0.0));

      // Stereo decorrelation: L and R should not be identical
      expect(outL, isNot(equals(outR)));
    });

    test('reproducible with explicit seed', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 256);
      final p1 = VinylNoiseProcessor(seed: 98765);
      final p2 = VinylNoiseProcessor(seed: 98765);

      final outL1 = Float32List(256);
      final outR1 = Float32List(256);
      final outL2 = Float32List(256);
      final outR2 = Float32List(256);

      p1.process(context, _inlets(vectorSize: 256), [outL1, outR1]);
      p2.process(context, _inlets(vectorSize: 256), [outL2, outR2]);

      expect(outL1, equals(outL2));
      expect(outR1, equals(outR2));
    });

    test('zero crackle, hiss, and warp produces silence', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 256);
      final processor = VinylNoiseProcessor(
        crackle: 0.0,
        hiss: 0.0,
        warp: 0.0,
        density: 0.0,
        seed: 42,
      );

      final outL = Float32List(256);
      final outR = Float32List(256);

      processor.process(context, _inlets(vectorSize: 256), [outL, outR]);

      expect(outL.every((s) => s == 0.0), isTrue);
      expect(outR.every((s) => s == 0.0), isTrue);
    });

    test('crackle only produces discrete transient clicks above zero baseline', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 1024);
      final processor = VinylNoiseProcessor(
        crackle: 0.8,
        hiss: 0.0,
        warp: 0.0,
        density: 100.0, // high density to guarantee clicks in 1024 samples
        seed: 1234,
      );

      final outL = Float32List(1024);
      final outR = Float32List(1024);

      processor.process(context, _inlets(vectorSize: 1024), [outL, outR]);

      // Many samples should be zero or decaying, with max spike noticeably high
      final maxL = outL.fold(0.0, (acc, s) => math.max(acc, s.abs()));
      final zeroCount = outL.where((s) => s.abs() < 1e-6).length;

      expect(maxL, greaterThan(0.01));
      expect(zeroCount, greaterThan(100)); // sparse clicks
    });

    test('supports audio-rate parameter modulation', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final processor = VinylNoiseProcessor(
        crackle: 0.0,
        hiss: null, // modulated via inlet
        warp: 0.0,
        density: 0.0,
        seed: 555,
      );

      final hissMod = Float32List(64); // all 0.0 -> silent
      final outL = Float32List(64);
      final outR = Float32List(64);

      processor.process(
        context,
        _inlets(hiss: hissMod, vectorSize: 64),
        [outL, outR],
      );

      expect(outL.every((s) => s == 0.0), isTrue);

      // Now unmute hiss via inlet
      hissMod.fillRange(0, 64, 1.0);
      processor.process(
        context,
        _inlets(hiss: hissMod, vectorSize: 64),
        [outL, outR],
      );

      final maxEnergy = outL.fold(0.0, (acc, s) => math.max(acc, s.abs()));
      expect(maxEnergy, greaterThan(0.0));
    });
  });

  group('VinylNoise graph and extensions', () {
    test('compiles and runs in GraphCompiler', () {
      final vinyl = VinylNoise(
        crackle: const .value(0.2),
        hiss: const .value(0.1),
        seed: 777,
      );

      final sum = Sum.pair(vinyl.left, vinyl.right);
      final context = ProcessContext(sampleRate: 44100, vectorSize: 128);
      final pipeline = compilePipeline(root: sum, context: context).pipeline!;

      pipeline.process();

      expect(pipeline.steps.isNotEmpty, isTrue);
      expect(pipeline.outputs[0].length, equals(128));
    });

    test('Outlet.addVinyl overlays vinyl onto mono signal', () {
      final osc = SineOscillator(frequency: const .value(440.0));
      final wet = osc.outlet.addVinyl(crackle: const .value(0.1));

      final context = ProcessContext(sampleRate: 44100, vectorSize: 128);
      final pipeline = compilePipeline(
        root: wet.node,
        context: context,
      ).pipeline!;

      pipeline.process();
      expect(pipeline.steps.length, greaterThanOrEqualTo(2));
      expect(pipeline.outputs[0].length, equals(128));
    });

    test(
      'Stereo (Outlet, Outlet).addVinyl overlays vinyl onto stereo pair',
      () {
        final oscL = SineOscillator(frequency: const .value(440.0));
        final oscR = SineOscillator(frequency: const .value(554.37));

        final (wetL, wetR) = (oscL.outlet, oscR.outlet).addVinyl(
          crackle: const .value(0.15),
        );

        final sum = Sum.pair(wetL, wetR);
        final context = ProcessContext(sampleRate: 44100, vectorSize: 128);
        final pipeline = compilePipeline(root: sum, context: context).pipeline!;

        pipeline.process();
        expect(pipeline.steps.length, greaterThanOrEqualTo(3));
        expect(pipeline.outputs[0].length, equals(128));
      },
    );
  });
}
