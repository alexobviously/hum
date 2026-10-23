import 'package:hum/hum.dart';
import 'package:test/test.dart';

class _LoopNode extends AudioNode<AudioProcessor> {
  @override
  List<Inlet> inlets = [];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  @override
  AudioProcessor createProcessor() => throw UnimplementedError();

  @override
  Object get params => ();
}

void main() {
  test('discoverNodes finds all upstream reachable nodes', () {
    final sine = SineOscillator(frequency: .value(440));
    final mult = Mult.mono(value: .value(0.5), input: sine.outlet);
    final pan = StereoPan(input: mult.outlets[0], pan: .value(0.0));
    final dac = Dac(channels: [pan.left, pan.right]);

    // An unattached node that should NOT be discovered
    final orphan = SineOscillator(frequency: .value(880));

    final discovered = discoverNodes([dac]);

    expect(discovered, containsAll([dac, pan, mult, sine]));
    expect(discovered, isNot(contains(orphan)));
    expect(discovered.length, equals(4));
  });

  test('topologicalSort sorts nodes in correct execution order', () {
    final sine = SineOscillator(frequency: .value(440));
    final mult = Mult.mono(value: .value(0.5), input: sine.outlet);
    final pan = StereoPan(input: mult.outlets[0], pan: .value(0.0));
    final dac = Dac(channels: [pan.left, pan.right]);

    final discovered = discoverNodes([dac]);
    final sorted = topologicalSort(discovered);

    expect(sorted.length, equals(4));
    expect(sorted.indexOf(sine), lessThan(sorted.indexOf(mult)));
    expect(sorted.indexOf(mult), lessThan(sorted.indexOf(pan)));
    expect(sorted.indexOf(pan), lessThan(sorted.indexOf(dac)));
  });

  test('topologicalSort detects cycles and throws GraphCycleException', () {
    final a = _LoopNode();
    final b = _LoopNode();

    a.inlets = [Inlet(node: a, index: 0, source: b.outlets.first)];
    b.inlets = [Inlet(node: b, index: 0, source: a.outlets.first)];

    expect(() => topologicalSort({a, b}), throwsA(isA<GraphCycleException>()));
  });

  test('compilePipeline builds and executes complete rendering pipeline', () {
    final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
    final sine = SineOscillator(frequency: .value(440));
    final mult = Mult.mono(value: .value(0.5), input: sine.outlet);
    final pan = StereoPan(input: mult.outlets[0], pan: .value(0.0));
    final dac = Dac(channels: [pan.left, pan.right]);

    final pipeline = compilePipeline(root: dac, context: context).pipeline!;
    expect(pipeline.steps.length, equals(4));
    expect(pipeline.numChannels, equals(2));

    // Render one block
    pipeline.process();

    final left = pipeline.outputs[0];
    final right = pipeline.outputs[1];

    expect(left.length, equals(64));
    expect(right.length, equals(64));

    // Center panning means left and right should be non-zero and equal
    expect(left[1], isNot(equals(0.0)));
    expect(left[1], closeTo(right[1], 1e-6));
  });

  test('AudioPipeline.update updates live processor without rebuild', () {
    final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
    final sine = SineOscillator(frequency: .value(440));
    final mult = Mult.mono(value: .value(1.0), input: sine.outlet);
    final pipeline = compilePipeline(root: mult, context: context).pipeline!;
    final processor = pipeline.processorOf(mult);
    expect(processor.value, equals(1.0));

    // Update mult node to 0.5
    final updatedMult = Mult.mono(value: .value(0.5), input: sine.outlet);
    pipeline.update(mult, updatedMult);

    expect(processor.value, equals(0.5));
  });

  group('Graph validation and CompileResult', () {
    test('validateGraph identifies invalid nodes without compiling', () {
      final validOsc = SineOscillator(frequency: const .value(440));
      final invalidSum = Sum(inputs: const []);

      final validDiagnostics = validateGraph([validOsc]);
      expect(validDiagnostics, isEmpty);

      final invalidDiagnostics = validateGraph([invalidSum]);
      expect(invalidDiagnostics.length, equals(1));
      final diag = invalidDiagnostics.first;
      expect(identical(diag.node, invalidSum), isTrue);
      expect(diag.errors.length, equals(1));
      expect(diag.errors.first, isA<AudioNodeParamError>());
      expect(diag.hasErrors, isTrue);
      expect(diag.toString(), contains('Sum: [inputs]: must not be empty'));
    });

    test(
      'compilePipeline returns CompileResult with switch pattern matching',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final osc = SineOscillator(frequency: const .value(440));

        final successResult = compilePipeline(root: osc, context: context);
        expect(successResult.isSuccess, isTrue);
        expect(successResult.isFailure, isFalse);
        expect(successResult.hasErrors, isFalse);

        final compiledPipeline = switch (successResult) {
          (:final pipeline?, diagnostics: _) => pipeline,
          _ => fail('Expected successful compilation'),
        };
        expect(compiledPipeline.numChannels, equals(1));

        // Test failure case with invalid node
        final badSum = Sum(inputs: const []);
        final failureResult = compilePipeline(root: badSum, context: context);
        expect(failureResult.isSuccess, isFalse);
        expect(failureResult.isFailure, isTrue);
        expect(failureResult.hasErrors, isTrue);
        expect(failureResult.pipeline, isNull);

        switch (failureResult) {
          case (pipeline: null, :final diagnostics):
            expect(diagnostics.length, equals(1));
            expect(identical(diagnostics.first.node, badSum), isTrue);
          case (pipeline: != null, diagnostics: _):
            fail('Expected compilation to fail');
        }
      },
    );
  });
}
