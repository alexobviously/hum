import 'dart:typed_data';

import 'package:dsp/dsp.dart';
import 'package:dsp/src/nodes/oscillators/oscillator_utils.dart';
import 'package:test/test.dart';

void main() {
  group('polyBlamp utility', () {
    test('returns 0.0 for out of bounds dt', () {
      expect(polyBlamp(0.1, 0.0), equals(0.0));
      expect(polyBlamp(0.1, -0.05), equals(0.0));
      expect(polyBlamp(0.1, 0.51), equals(0.0));
    });

    test('is symmetric and continuous across phase boundary', () {
      const dt = 0.1;
      expect(polyBlamp(0.0, dt), closeTo(1.0 / 3.0, 1e-9));
      expect(polyBlamp(1.0 - 1e-12, dt), closeTo(1.0 / 3.0, 1e-6));
      expect(polyBlamp(dt, dt), closeTo(0.0, 1e-9));
      expect(polyBlamp(1.0 - dt, dt), closeTo(0.0, 1e-9));
      expect(polyBlamp(0.5, dt), equals(0.0));
    });

    test('derivative matches polyBlep', () {
      const dt = 0.1;
      const epsilon = 1e-6;

      for (final phase in [0.02, 0.05, 0.08, 0.92, 0.95, 0.98]) {
        final dBlamp =
            (polyBlamp(phase + epsilon, dt) - polyBlamp(phase - epsilon, dt)) /
            (2 * epsilon);
        final numericalDerivative = dt * dBlamp;
        final expectedBlep = polyBlep(phase, dt);
        expect(numericalDerivative, closeTo(expectedBlep, 1e-4));
      }
    });
  });

  group('TriangleOscillator node', () {
    test('has expected inlets, outlets, and params', () {
      final osc = TriangleOscillator(frequency: .value(220));

      expect(osc.inlets.length, equals(1));
      expect(osc.inlets.first.source, isNull);
      expect(osc.outlets.length, equals(1));
      expect(osc.outlet, equals(osc.outlets.first));
      expect(osc.params.frequency, equals(220.0));
      expect(osc.params.usePolyBlep, isTrue);

      final processor = osc.createProcessor();
      expect(processor.frequency, equals(220.0));
      expect(processor.usePolyBlep, isTrue);
    });

    test('supports scale extension from OscillatorNode', () {
      final osc = TriangleOscillator(frequency: .value(440));
      final scaled = osc.scale(0.0, 1.0);

      expect(scaled.inlets.first.source, equals(osc.outlet));
    });

    test('processes constant frequency in compiled pipeline', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final osc = TriangleOscillator(frequency: .value(440));
      final pipeline = compilePipeline(root: osc, context: context);

      pipeline.process();
      final output = pipeline.outputs[0];

      expect(output.length, equals(64));
      expect(output.every((s) => s >= -1.0 && s <= 1.0), isTrue);
    });

    test('processes signal frequency modulation inlet', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final lfo = SineOscillator(frequency: .value(2)).scale(200.0, 400.0);
      final osc = TriangleOscillator(frequency: .signal(lfo.outlet));
      final pipeline = compilePipeline(root: osc, context: context);

      pipeline.process();
      final output = pipeline.outputs[0];

      expect(output.length, equals(64));
      expect(output.every((s) => s >= -1.0 && s <= 1.0), isTrue);
    });

    test('processor update updates live parameters', () {
      final processor = TriangleOscillatorProcessor(
        frequency: 100,
        usePolyBlep: true,
      );
      expect(processor.frequency, equals(100));
      expect(processor.usePolyBlep, isTrue);

      processor.update((frequency: 440.0, usePolyBlep: false));
      expect(processor.frequency, equals(440.0));
      expect(processor.usePolyBlep, isFalse);
    });

    test('produces expected raw and antialiased samples across cycles', () {
      final context = ProcessContext(sampleRate: 16, vectorSize: 16);
      final rawOut = Float32List(16);
      final polyOut = Float32List(16);

      TriangleOscillatorProcessor(
        frequency: 1,
        usePolyBlep: false,
      ).process(context, [], [rawOut]);

      TriangleOscillatorProcessor(
        frequency: 1,
        usePolyBlep: true,
      ).process(context, [], [polyOut]);

      // At phase 0 (t = 0), naive is 0.0
      expect(rawOut[0], closeTo(0.0, 1e-6));
      // At phase 0.25 (sample index 4), naive reaches peak 1.0
      expect(rawOut[4], closeTo(1.0, 1e-6));
      // At phase 0.5 (sample index 8), naive reaches 0.0
      expect(rawOut[8], closeTo(0.0, 1e-6));
      // At phase 0.75 (sample index 12), naive reaches trough -1.0
      expect(rawOut[12], closeTo(-1.0, 1e-6));

      // PolyBLAMP rounds the sharp corners slightly inward
      expect(polyOut[4], lessThan(1.0));
      expect(polyOut[4], greaterThan(0.9));
      expect(polyOut[12], greaterThan(-1.0));
      expect(polyOut[12], lessThan(-0.9));

      // Waveform remains fully bounded
      expect(polyOut.every((s) => s >= -1.0 && s <= 1.0), isTrue);
    });
  });
}
