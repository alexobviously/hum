import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('AudioHost.sync', () {
    test('compiles graph, dispatches diff, and renders audio', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = SyncAudioHost(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final mult = Mult.mono(value: const .value(0.5), input: osc.outlet);

      final diagnostics = host.setGraph(root: mult);
      expect(diagnostics, isEmpty);
      expect(host.currentSnapshot.nodes.length, equals(2));
      expect(host.numChannels, equals(1));

      // Process block
      host.process();
      expect(host.outputs[0].length, equals(64));
      expect(host.outputs[0][1], isNot(equals(0.0)));
    });

    test('returns diagnostics on invalid graph without updating snapshot', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = SyncAudioHost(context: context);

      final invalidSum = Sum(inputs: const []);
      final diagnostics = host.setGraph(root: invalidSum);

      expect(diagnostics.length, equals(1));
      expect(identical(diagnostics.first.node, invalidSum), isTrue);
      expect(host.currentSnapshot.isEmpty, isTrue);
    });

    test('update and updateById update processor in-place', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = SyncAudioHost(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      host.setGraph(root: osc);

      final proc = host.processorOf<SineOscillatorProcessor>(osc)!;
      expect(proc.frequency, equals(440.0));

      // Update via node reference
      host.update(osc, (frequency: 880.0));
      expect(proc.frequency, equals(880.0));

      // Update via ID
      final oscId = host.currentSnapshot.nodeIds[osc]!;
      host.updateById(oscId, (frequency: 220.0));
      expect(proc.frequency, equals(220.0));
    });

    test('renderBlocks renders requested count of blocks', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = AudioHost.sync(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      host.setGraph(root: osc);

      final blocks = await host.renderBlocks(5);
      expect(blocks.length, equals(5));
      for (final block in blocks) {
        expect(block.length, equals(64));
      }
    });
  });

  group('AudioHost.spawn (isolate mode)', () {
    test(
      'spawns isolate, applies graph, and renders audio across boundary',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await AudioHost.spawn(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        final mult = Mult.mono(value: const .value(0.5), input: osc.outlet);

        final diagnostics = host.setGraph(root: mult);
        expect(diagnostics, isEmpty);
        expect(host.currentSnapshot.nodes.length, equals(2));

        // Render blocks across isolate boundary
        final blocks440 = await host.renderBlocks(2);
        expect(blocks440.length, equals(2));
        expect(blocks440[0].length, equals(64));
        expect(blocks440[0][1], isNot(equals(0.0)));

        // Fast-path parameter update across isolate boundary
        host.update(osc, (frequency: 880.0));

        final blocks880 = await host.renderBlocks(2);
        expect(blocks880.length, equals(2));
        expect(blocks880[0].length, equals(64));

        // Clean disposal
        await host.dispose();

        // Subsequent operations throw StateError
        expect(
          () => host.setGraph(root: osc),
          throwsStateError,
        );
      },
    );

    test(
      'returns diagnostics on invalid graph without sending to worker',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await AudioHost.spawn(context: context);

        final invalidSum = Sum(inputs: const []);
        final diagnostics = host.setGraph(root: invalidSum);

        expect(diagnostics.length, equals(1));
        expect(identical(diagnostics.first.node, invalidSum), isTrue);
        expect(host.currentSnapshot.isEmpty, isTrue);

        await host.dispose();
      },
    );
  });
}
