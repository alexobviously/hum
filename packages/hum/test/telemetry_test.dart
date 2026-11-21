import 'dart:async';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:test/test.dart';

void main() {
  group('Telemetry pipeline (SyncAudioHost)', () {
    test('emits StepSequencer step index on latest and stream', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(
        context: context,
        telemetryInterval: const Duration(milliseconds: 10),
      );

      final clock = Clock(
        frequency: const .value(25.0), // 1 step every 40 ms
        pulseWidth: const .value(0.5),
      );
      final seq = StepSequencer.fromList(
        clock: clock.trigger,
        steps: const [100, 200, 300, 400],
      );
      final out = Out.mono(seq.outlet);
      expect(host.setGraph(root: out), isEmpty);

      final channel = host.telemetryOf(seq);
      expect(channel, isNotNull);
      expect(channel!.latest, isNull);
      expect(identical(seq.telemetry(host), channel), isTrue);

      final observed = <int>[];
      final sub = channel.stream.listen(observed.add);

      // Render 200 ms = 9600 samples = 150 blocks of 64.
      await host.renderBlocks(150);
      await Future<void>.delayed(Duration.zero);

      expect(observed, containsAllInOrder([0, 1, 2, 3]));
      expect(channel.latest, equals(observed.last));

      await sub.cancel();
      await host.dispose();
      expect(channel.isClosed, isTrue);
    });

    test('subscription survives declarative setGraph() diffs', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(
        context: context,
        telemetryInterval: const Duration(milliseconds: 10),
      );

      StepSequencer buildAndSet(double freq) {
        final clock = Clock(
          frequency: .value(freq),
          pulseWidth: const .value(0.5),
        );
        final seq = StepSequencer.fromList(
          clock: clock.trigger,
          steps: const [100, 200, 300, 400],
        );
        expect(host.setGraph(root: Out.mono(seq.outlet)), isEmpty);
        return seq;
      }

      final seq1 = buildAndSet(25.0);
      final channel = host.telemetryOf(seq1)!;

      final observed = <int>[];
      final sub = channel.stream.listen(observed.add);

      await host.renderBlocks(40);
      final countBeforeRebuild = observed.length;
      expect(countBeforeRebuild, greaterThan(0));

      // Rebuild graph with a brand-new StepSequencer instance; GraphDiff keeps
      // the same nodeId, so the existing channel continues receiving updates.
      final seq2 = buildAndSet(25.0);
      expect(identical(host.telemetryOf(seq2), channel), isTrue);
      expect(channel.isClosed, isFalse);

      await host.renderBlocks(120);
      await Future<void>.delayed(Duration.zero);

      expect(observed.length, greaterThan(countBeforeRebuild));

      // Removing the StepSequencer from the graph closes its channel.
      final osc = SineOscillator(frequency: const .value(440));
      expect(host.setGraph(root: Out.mono(osc.outlet)), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(channel.isClosed, isTrue);

      await sub.cancel();
      await host.dispose();
    });

    test('returns null for a node not in the compiled graph', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(context: context);
      final clock = Clock(frequency: const .value(10.0));
      final unused = StepSequencer.fromList(
        clock: clock.trigger,
        steps: const [1, 2],
      );

      expect(host.telemetryOf(unused), isNull);
      await host.dispose();
    });
  });

  group('Telemetry pipeline (IsolateAudioHost)', () {
    test('streams StepSequencer telemetry across isolate boundary', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = await IsolateAudioHost.spawn(
        context: context,
        telemetryInterval: const Duration(milliseconds: 10),
      );
      try {
        final clock = Clock(
          frequency: const .value(25.0),
          pulseWidth: const .value(0.5),
        );
        final seq = StepSequencer.fromList(
          clock: clock.trigger,
          steps: const [100, 200, 300, 400],
        );
        expect(host.setGraph(root: Out.mono(seq.outlet)), isEmpty);

        final channel = host.telemetryOf(seq)!;
        final observed = <int>[];
        final done = Completer<void>();
        final sub = channel.stream.listen((step) {
          observed.add(step);
          if (observed.length >= 3 && !done.isCompleted) {
            done.complete();
          }
        });

        await host.renderBlocks(150);
        await done.future.timeout(const Duration(seconds: 2));

        expect(observed, containsAllInOrder([0, 1, 2]));
        expect(channel.latest, isNotNull);

        await sub.cancel();
      } finally {
        await host.dispose();
      }
    });
  });
}
