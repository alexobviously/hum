import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('AudioEngine', () {
    test('initial diff instantiates processors, wires buffers, and processes block', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final engine = AudioEngine(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final mult = Mult.mono(value: const .value(0.5), input: osc.outlet);

      final snapshot = compileGraph(root: mult).snapshot!;
      final diff = diffGraph(GraphSnapshot.empty, snapshot);

      engine.applyDiff(diff);

      expect(engine.processorCount, equals(2));
      expect(engine.stepCount, equals(2));
      expect(engine.numChannels, equals(1));
      expect(engine.bufferPoolSize, greaterThanOrEqualTo(2));

      // Process one block
      engine.process();

      final output = engine.outputs[0];
      expect(output.length, equals(64));
      // Non-zero sine wave samples generated
      expect(output[1], isNot(equals(0.0)));
    });

    test('in-place parameter update via applyDiff preserves processor and phase continuity', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final engine = AudioEngine(context: context);

      final osc1 = SineOscillator(frequency: const .value(440));
      final snapshot1 = compileGraph(root: osc1).snapshot!;
      final diff1 = diffGraph(GraphSnapshot.empty, snapshot1);
      engine.applyDiff(diff1);

      final oscId = diff1.snapshot.nodeIds[osc1]!;
      final processorBefore = engine.processorOf<SineOscillatorProcessor>(
        oscId,
      )!;

      // Render block 1 at 440 Hz
      engine.process();
      final phaseAfterBlock1 = processorBefore.phase;

      // Update frequency to 880 Hz
      final osc2 = SineOscillator(frequency: const .value(880));
      final snapshot2 = compileGraph(root: osc2).snapshot!;
      final diff2 = diffGraph(diff1.snapshot, snapshot2);

      expect(diff2.hasScheduleChange, isFalse);
      expect(diff2.updatedParams.containsKey(oscId), isTrue);

      engine.applyDiff(diff2);

      // Verify processor instance was retained in-place
      final processorAfter = engine.processorOf<SineOscillatorProcessor>(
        oscId,
      )!;
      expect(identical(processorBefore, processorAfter), isTrue);
      expect(processorAfter.frequency, equals(880.0));
      // Phase was preserved across block boundary
      expect(processorAfter.phase, equals(phaseAfterBlock1));

      // Render block 2 at 880 Hz
      engine.process();
      expect(processorAfter.phase, isNot(equals(phaseAfterBlock1)));
    });

    test('fast-path updateParam updates processor directly without diff', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final engine = AudioEngine(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final snapshot = compileGraph(root: osc).snapshot!;
      final diff = diffGraph(GraphSnapshot.empty, snapshot);
      engine.applyDiff(diff);

      final oscId = diff.snapshot.nodeIds[osc]!;
      final processor = engine.processorOf<SineOscillatorProcessor>(oscId)!;
      expect(processor.frequency, equals(440.0));

      // Fast-path direct update
      engine.updateParam(oscId, (frequency: 220.0));
      expect(processor.frequency, equals(220.0));
    });

    test(
      'structural addition keeps existing processors alive and adds new step',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final engine = AudioEngine(context: context);

        final osc1 = SineOscillator(frequency: const .value(440));
        final snapshot1 = compileGraph(root: osc1).snapshot!;
        final diff1 = diffGraph(GraphSnapshot.empty, snapshot1);
        engine.applyDiff(diff1);

        final oscId = diff1.snapshot.nodeIds[osc1]!;
        final oscProcBefore = engine.processorOf<SineOscillatorProcessor>(
          oscId,
        )!;

        // Add a Bitcrusher effect
        final osc2 = SineOscillator(frequency: const .value(440));
        final crush = Bitcrusher.mono(
          input: osc2.outlet,
          bitDepth: const .value(8.0),
        );
        final snapshot2 = compileGraph(root: crush).snapshot!;
        final diff2 = diffGraph(diff1.snapshot, snapshot2);

        engine.applyDiff(diff2);

        expect(engine.processorCount, equals(2));
        expect(engine.stepCount, equals(2));

        // Oscillator processor was kept alive
        final oscProcAfter = engine.processorOf<SineOscillatorProcessor>(
          oscId,
        )!;
        expect(identical(oscProcBefore, oscProcAfter), isTrue);

        // Bitcrusher processor was instantiated
        final crushId = diff2.snapshot.nodeIds[crush]!;
        final crushProc = engine.processorOf<BitcrusherProcessor>(crushId);
        expect(crushProc, isNotNull);

        // Renders with effect active
        engine.process();
        expect(engine.outputs[0].length, equals(64));
      },
    );

    test(
      'structural removal disposes removed processor and updates schedule',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final engine = AudioEngine(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        final crush = Bitcrusher.mono(
          input: osc.outlet,
          bitDepth: const .value(8.0),
        );
        final snapshot1 = compileGraph(root: crush).snapshot!;
        final diff1 = diffGraph(GraphSnapshot.empty, snapshot1);
        engine.applyDiff(diff1);

        final crushId = diff1.snapshot.nodeIds[crush]!;
        expect(engine.processorOf(crushId), isNotNull);
        expect(engine.stepCount, equals(2));

        // Remove crush
        final osc2 = SineOscillator(frequency: const .value(440));
        final snapshot2 = compileGraph(root: osc2).snapshot!;
        final diff2 = diffGraph(diff1.snapshot, snapshot2);

        engine.applyDiff(diff2);

        expect(engine.stepCount, equals(1));
        expect(engine.processorOf(crushId), isNull);
      },
    );

    test(
      'incompatible node recreation disposes old and boots new processor',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final engine = AudioEngine(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        final chorus1 = Chorus.toStereo(
          input: osc.outlet,
          stereoPhase: 0.0,
        );
        final snapshot1 = compileGraph(root: chorus1).snapshot!;
        final diff1 = diffGraph(GraphSnapshot.empty, snapshot1);
        engine.applyDiff(diff1);

        final oldChorusId = diff1.snapshot.nodeIds[chorus1]!;
        final oscId = diff1.snapshot.nodeIds[osc]!;
        final oldChorusProc = engine.processorOf<ChorusProcessor>(oldChorusId)!;
        final oscProc = engine.processorOf<SineOscillatorProcessor>(oscId)!;

        // Incompatible change: stereoPhase changes from 0 to 1.57 (canUpdate is false)
        final osc2 = SineOscillator(frequency: const .value(440));
        final chorus2 = Chorus.toStereo(
          input: osc2.outlet,
          stereoPhase: 1.57,
        );
        final snapshot2 = compileGraph(root: chorus2).snapshot!;
        final diff2 = diffGraph(diff1.snapshot, snapshot2);

        engine.applyDiff(diff2);

        // Old chorus was disposed
        expect(engine.processorOf(oldChorusId), isNull);

        // New chorus processor instantiated
        final newChorusId = diff2.snapshot.nodeIds[chorus2]!;
        final newChorusProc = engine.processorOf<ChorusProcessor>(newChorusId)!;
        expect(identical(oldChorusProc, newChorusProc), isFalse);

        // Sibling oscillator was preserved
        final currentOscProc = engine.processorOf<SineOscillatorProcessor>(
          oscId,
        )!;
        expect(identical(oscProc, currentOscProc), isTrue);
      },
    );

    test('renders multi-channel stereo audio', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final engine = AudioEngine(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final pan = StereoPan(input: osc.outlet, pan: const .value(0.0));
      final dac = Dac(channels: [pan.left, pan.right]);

      final snapshot = compileGraph(root: dac).snapshot!;
      final diff = diffGraph(GraphSnapshot.empty, snapshot);
      engine.applyDiff(diff);

      expect(engine.numChannels, equals(2));

      engine.process();

      final left = engine.outputs[0];
      final right = engine.outputs[1];

      expect(left.length, equals(64));
      expect(right.length, equals(64));
      // Centered panning means left and right are equal and non-zero
      expect(left[1], isNot(equals(0.0)));
      expect(left[1], closeTo(right[1], 1e-6));
    });

    test('topologyEpoch increments only when schedule changes', () {
      const context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      expect(context.epoch, equals(0));

      final engine = AudioEngine(context: context);
      expect(engine.topologyEpoch, equals(0));

      // Initial graph -> epoch 1.
      final osc1 = SineOscillator(frequency: const .value(440));
      final snap1 = compileGraph(root: Out.mono(osc1.outlet)).snapshot!;
      final diff1 = diffGraph(GraphSnapshot.empty, snap1);
      engine.applyDiff(diff1);
      expect(engine.topologyEpoch, equals(1));

      // Param-only update -> schedule unchanged -> epoch stays 1.
      final osc2 = SineOscillator(frequency: const .value(880));
      final snap2 = compileGraph(root: Out.mono(osc2.outlet)).snapshot!;
      final diff2 = diffGraph(diff1.snapshot, snap2);
      engine.applyDiff(diff2);
      expect(engine.topologyEpoch, equals(1));

      // Topology change (insert Mult) -> epoch 2.
      final osc3 = SineOscillator(frequency: const .value(880));
      final mult = Mult.mono(input: osc3.outlet, value: const .value(0.5));
      final snap3 = compileGraph(root: Out.mono(mult.outlet)).snapshot!;
      final diff3 = diffGraph(diff2.snapshot, snap3);
      engine.applyDiff(diff3);
      expect(engine.topologyEpoch, equals(2));
    });

    test(
      'SIMD processors rebind views on epoch bump even when output buffer is identical',
      () {
        const baseCtx = ProcessContext(sampleRate: 48000, vectorSize: 16);
        final ctx1 = baseCtx.withEpoch(1);
        final ctx2 = baseCtx.withEpoch(2);

        final inA = Float32List(16)..fillRange(0, 16, 1.0);
        final inB = Float32List(16)..fillRange(0, 16, 2.0);
        final inC = Float32List(16)..fillRange(0, 16, 5.0);
        final sameOut = Float32List(16);

        // Sum: swap second input buffer while keeping `sameOut` identical.
        final sum = SumProcessor(numInputs: 2);
        sum.process(ctx1, [inA, inB], [sameOut]);
        expect(sameOut[0], closeTo(3.0, 1e-6));
        sum.process(ctx2, [inA, inC], [sameOut]);
        expect(sameOut[0], closeTo(6.0, 1e-6));

        // Mult: swap input buffer while keeping `sameOut` identical.
        final mult = MultProcessor(value: 2.0, numChannels: 1, interpTime: 0.0);
        final emptyVal = Float32List(16);
        mult.process(ctx1, [emptyVal, inA], [sameOut]);
        expect(sameOut[0], closeTo(2.0, 1e-6));
        mult.process(ctx2, [emptyVal, inC], [sameOut]);
        expect(sameOut[0], closeTo(10.0, 1e-6));

        // Crossfade: swap input B buffer while keeping `sameOut` identical.
        final xfade = CrossfadeProcessor(
          numChannels: 1,
          position: 1.0,
          mode: .linear,
          interpTime: 0.0,
        );
        xfade.process(ctx1, [emptyVal, inA, inB], [sameOut]);
        expect(sameOut[0], closeTo(2.0, 1e-6));
        xfade.process(ctx2, [emptyVal, inA, inC], [sameOut]);
        expect(sameOut[0], closeTo(5.0, 1e-6));
      },
    );
  });
}
