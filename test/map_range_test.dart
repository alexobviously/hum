import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('MapRange', () {
    test('declares expected inlets and outlets', () {
      final osc = SineOscillator(frequency: const .value(440));
      final mapped = MapRange(
        input: osc.outlet,
        inLow: const .value(-1.0),
        inHigh: const .value(1.0),
        outLow: const .value(100.0),
        outHigh: const .value(1000.0),
      );

      expect(mapped.inlets.length, equals(1));
      expect(mapped.inlets.first.source, equals(osc.outlet));
      expect(mapped.outlets.length, equals(1));
      expect(mapped.outlet, equals(mapped.outlets.first));
    });

    test('linearly maps input range to output range', () {
      final proc = MapRangeProcessor(
        inLow: -1.0,
        inHigh: 1.0,
        outLow: 100.0,
        outHigh: 500.0,
      );

      final context = ProcessContext(sampleRate: 44100, vectorSize: 5);
      final inBuf = Float32List.fromList([-1.0, -0.5, 0.0, 0.5, 1.0]);
      final outBuf = Float32List(5);

      proc.process(context, [inBuf], [outBuf]);

      expect(outBuf[0], closeTo(100.0, 1e-4));
      expect(outBuf[1], closeTo(200.0, 1e-4));
      expect(outBuf[2], closeTo(300.0, 1e-4));
      expect(outBuf[3], closeTo(400.0, 1e-4));
      expect(outBuf[4], closeTo(500.0, 1e-4));
    });

    test('MapRange.bipolar factory maps [-1.0, 1.0] to target range', () {
      final osc = SineOscillator(frequency: const .value(440));
      final mapped = MapRange.bipolar(
        input: osc.outlet,
        outLow: 200.0,
        outHigh: 800.0,
      );

      expect(mapped.inLow.value, equals(-1.0));
      expect(mapped.inHigh.value, equals(1.0));
      expect(mapped.outLow.value, equals(200.0));
      expect(mapped.outHigh.value, equals(800.0));
    });

    test('MapRange.unipolar factory maps [0.0, 1.0] to target range', () {
      final clock = Clock(frequency: const .value(1));
      final mapped = MapRange.unipolar(
        input: clock.gate,
        outLow: 50.0,
        outHigh: 150.0,
      );

      expect(mapped.inLow.value, equals(0.0));
      expect(mapped.inHigh.value, equals(1.0));
      expect(mapped.outLow.value, equals(50.0));
      expect(mapped.outHigh.value, equals(150.0));
    });

    test('Outlet.mapRange extension maps signal', () {
      final osc = SineOscillator(frequency: const .value(440));
      final mapped = osc.outlet.mapRange(0.0, 1.0);

      expect(mapped.input, equals(osc.outlet));
      expect(mapped.inLow.value, equals(-1.0));
      expect(mapped.inHigh.value, equals(1.0));
      expect(mapped.outLow.value, equals(0.0));
      expect(mapped.outHigh.value, equals(1.0));
    });

    test('update() modifies processor parameters in-place', () {
      final proc = MapRangeProcessor(
        inLow: 0.0,
        inHigh: 1.0,
        outLow: 0.0,
        outHigh: 10.0,
      );

      final context = ProcessContext(sampleRate: 44100, vectorSize: 2);
      final inBuf = Float32List.fromList([0.0, 1.0]);
      final outBuf = Float32List(2);

      proc.process(context, [inBuf], [outBuf]);
      expect(outBuf[0], equals(0.0));
      expect(outBuf[1], equals(10.0));

      proc.update((inLow: 0.0, inHigh: 1.0, outLow: 100.0, outHigh: 200.0));
      proc.process(context, [inBuf], [outBuf]);
      expect(outBuf[0], equals(100.0));
      expect(outBuf[1], equals(200.0));
    });

    test('compiles and renders inside AudioPipeline', () {
      final osc = SineOscillator(frequency: const .value(100));
      final mapped = osc.mapRange(200.0, 400.0);

      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final result = compilePipeline(root: mapped.outlet.out, context: context);
      expect(result.pipeline, isNotNull);

      final pipeline = result.pipeline!;
      pipeline.process();
      final buffers = pipeline.outputs;
      expect(buffers.length, equals(1));

      for (int i = 0; i < 64; i++) {
        expect(buffers[0][i], greaterThanOrEqualTo(199.9));
        expect(buffers[0][i], lessThanOrEqualTo(400.1));
      }
    });
  });
}

class DummyNode extends AudioNode<DummyProcessor> {
  @override
  List<Inlet> get inlets => const [];
  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];
  @override
  DummyProcessor createProcessor() => DummyProcessor();
  @override
  List<Object?> get fixedProps => const [];
  @override
  List<Object?> get dynamicProps => const [];
  @override
  Object get params => const Object();
}

class DummyProcessor implements AudioProcessor {
  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {}
  @override
  void update(Object params) {}
}
