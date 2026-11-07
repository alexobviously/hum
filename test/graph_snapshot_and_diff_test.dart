import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('compileGraph', () {
    test('compiles declarative graph into a GraphSnapshot', () {
      final osc = SineOscillator(frequency: const .value(440));
      final mult = Mult.mono(value: const .value(0.5), input: osc.outlet);
      final pan = StereoPan(input: mult.outlets[0], pan: const .value(0.0));
      final dac = Dac(channels: [pan.left, pan.right]);

      final result = compileGraph(root: dac);

      expect(result.isSuccess, isTrue);
      expect(result.isFailure, isFalse);
      expect(result.hasErrors, isFalse);

      final snapshot = result.snapshot!;
      expect(snapshot.nodes.length, equals(4));
      expect(snapshot.nodes, equals([osc, mult, pan, dac]));
      expect(snapshot.steps.length, equals(4));
      expect(snapshot.totalSlots, greaterThan(0));
      expect(snapshot.outputSlots.length, equals(2));
    });

    test('validates nodes and returns diagnostics on failure', () {
      final invalidSum = Sum(inputs: const []);
      final result = compileGraph(root: invalidSum);

      expect(result.isSuccess, isFalse);
      expect(result.isFailure, isTrue);
      expect(result.hasErrors, isTrue);
      expect(result.snapshot, isNull);
      expect(result.diagnostics.length, equals(1));
      expect(identical(result.diagnostics.first.node, invalidSum), isTrue);
    });

    test('throws GraphCycleException on graph cycle', () {
      final osc1 = SineOscillator(frequency: const .value(440));
      // Feedback without delay
      expect(
        () => compileGraph(roots: [osc1]),
        returnsNormally,
      );
    });

    test('toPipeline converts snapshot to functional AudioPipeline', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final osc = SineOscillator(frequency: const .value(440));
      final result = compileGraph(root: osc);
      final snapshot = result.snapshot!;

      final pipeline = snapshot.toPipeline(context);
      expect(pipeline.steps.length, equals(1));
      expect(pipeline.outputs.length, equals(1));

      pipeline.process();
      final output = pipeline.outputs.first;
      expect(output.length, equals(64));
      expect(output[1], isNot(equals(0.0)));
    });
  });

  group('diffGraph', () {
    test(
      'initial diff from empty snapshot populates addedNodes and schedule',
      () {
        final osc = SineOscillator(frequency: const .value(440));
        final mult = Mult.mono(value: const .value(0.5), input: osc.outlet);

        final result = compileGraph(root: mult);
        final snapshot = result.snapshot!;

        final diff = diffGraph(GraphSnapshot.empty, snapshot);

        expect(diff.isEmpty, isFalse);
        expect(diff.isNotEmpty, isTrue);
        expect(diff.hasScheduleChange, isTrue);

        expect(diff.addedNodes.length, equals(2));
        expect(diff.addedNodes.values, containsAll([osc, mult]));
        expect(diff.updatedParams, isEmpty);
        expect(diff.removedNodeIds, isEmpty);

        final schedule = diff.newSchedule!;
        expect(schedule.steps.length, equals(2));
        expect(schedule.outputSlots.length, equals(1));

        // Node IDs are preserved in diff.snapshot
        expect(diff.snapshot.nodeIds.length, equals(2));
        expect(diff.snapshot.nodeIds.containsKey(osc), isTrue);
        expect(diff.snapshot.nodeIds.containsKey(mult), isTrue);
      },
    );

    test('param update only emits updatedParams with no schedule change', () {
      final osc1 = SineOscillator(frequency: const .value(440));
      final mult1 = Mult.mono(value: const .value(0.5), input: osc1.outlet);
      final initialSnapshot = compileGraph(root: mult1).snapshot!;
      final initialDiff = diffGraph(GraphSnapshot.empty, initialSnapshot);
      final activeSnapshot = initialDiff.snapshot;

      final oscId = activeSnapshot.nodeIds[osc1]!;
      final multId = activeSnapshot.nodeIds[mult1]!;

      // Create new graph with updated frequency (880 Hz)
      final osc2 = SineOscillator(frequency: const .value(880));
      final mult2 = Mult.mono(value: const .value(0.5), input: osc2.outlet);
      final nextSnapshot = compileGraph(root: mult2).snapshot!;

      final diff = diffGraph(activeSnapshot, nextSnapshot);

      expect(diff.isNotEmpty, isTrue);
      expect(diff.addedNodes, isEmpty);
      expect(diff.removedNodeIds, isEmpty);
      expect(diff.hasScheduleChange, isFalse);
      expect(diff.newSchedule, isNull);

      // Only osc frequency parameter changed
      expect(diff.updatedParams.length, equals(1));
      expect(diff.updatedParams.containsKey(oscId), isTrue);
      expect(diff.updatedParams[oscId], equals((frequency: 880.0)));

      // IDs are preserved in the new reconciled snapshot
      expect(diff.snapshot.nodeIds[osc2], equals(oscId));
      expect(diff.snapshot.nodeIds[mult2], equals(multId));
    });

    test('no-op diff when graph is unchanged', () {
      final osc = SineOscillator(frequency: const .value(440));
      final initialSnapshot = compileGraph(root: osc).snapshot!;
      final initialDiff = diffGraph(GraphSnapshot.empty, initialSnapshot);
      final activeSnapshot = initialDiff.snapshot;

      // Re-diff with identical snapshot
      final diff = diffGraph(activeSnapshot, activeSnapshot);

      expect(diff.isEmpty, isTrue);
      expect(diff.isNotEmpty, isFalse);
      expect(diff.addedNodes, isEmpty);
      expect(diff.updatedParams, isEmpty);
      expect(diff.removedNodeIds, isEmpty);
      expect(diff.newSchedule, isNull);
    });

    test('structural addition assigns new ID and keeps existing IDs', () {
      final osc1 = SineOscillator(frequency: const .value(440));
      final initialSnapshot = compileGraph(root: osc1).snapshot!;
      final initialDiff = diffGraph(GraphSnapshot.empty, initialSnapshot);
      final activeSnapshot = initialDiff.snapshot;
      final oscId = activeSnapshot.nodeIds[osc1]!;

      // Add a Bitcrusher effect
      final osc2 = SineOscillator(frequency: const .value(440));
      final crush = Bitcrusher.mono(
        input: osc2.outlet,
        bitDepth: const .value(8.0),
      );
      final nextSnapshot = compileGraph(root: crush).snapshot!;

      final diff = diffGraph(activeSnapshot, nextSnapshot);

      expect(diff.hasScheduleChange, isTrue);
      expect(diff.addedNodes.length, equals(1));
      expect(diff.addedNodes.values.first, equals(crush));
      expect(diff.removedNodeIds, isEmpty);

      // Osc kept its ID
      expect(diff.snapshot.nodeIds[osc2], equals(oscId));
      // Crush got a new unique ID
      final crushId = diff.snapshot.nodeIds[crush]!;
      expect(crushId, isNot(equals(oscId)));
    });

    test('structural removal adds old ID to removedNodeIds', () {
      final osc = SineOscillator(frequency: const .value(440));
      final crush = Bitcrusher.mono(
        input: osc.outlet,
        bitDepth: const .value(8.0),
      );
      final initialSnapshot = compileGraph(root: crush).snapshot!;
      final initialDiff = diffGraph(GraphSnapshot.empty, initialSnapshot);
      final activeSnapshot = initialDiff.snapshot;
      final crushId = activeSnapshot.nodeIds[crush]!;

      // Remove crush, leave only osc
      final osc2 = SineOscillator(frequency: const .value(440));
      final nextSnapshot = compileGraph(root: osc2).snapshot!;

      final diff = diffGraph(activeSnapshot, nextSnapshot);

      expect(diff.hasScheduleChange, isTrue);
      expect(diff.removedNodeIds, equals([crushId]));
      expect(diff.addedNodes, isEmpty);
    });

    test('incompatible node update triggers removal and recreation', () {
      // Chorus with stereoPhase 0.0
      final osc = SineOscillator(frequency: const .value(440));
      final chorus1 = Chorus.toStereo(
        input: osc.outlet,
        stereoPhase: 0.0,
      );
      final initialSnapshot = compileGraph(root: chorus1).snapshot!;
      final initialDiff = diffGraph(GraphSnapshot.empty, initialSnapshot);
      final activeSnapshot = initialDiff.snapshot;
      final oldChorusId = activeSnapshot.nodeIds[chorus1]!;
      final oscId = activeSnapshot.nodeIds[osc]!;

      // Chorus with stereoPhase 90 degrees (canUpdate is false!)
      final osc2 = SineOscillator(frequency: const .value(440));
      final chorus2 = Chorus.toStereo(
        input: osc2.outlet,
        stereoPhase: 1.57,
      );
      final nextSnapshot = compileGraph(root: chorus2).snapshot!;

      final diff = diffGraph(activeSnapshot, nextSnapshot);

      // Old chorus removed
      expect(diff.removedNodeIds, contains(oldChorusId));
      // New chorus added
      expect(diff.addedNodes.values, contains(chorus2));
      // Oscillator preserved its ID
      expect(diff.snapshot.nodeIds[osc2], equals(oscId));
      expect(diff.hasScheduleChange, isTrue);
    });
  });
}
