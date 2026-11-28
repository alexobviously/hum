import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Branch', () {
    test('declares N outlets, supports operator [], and validates params', () {
      final clock = Clock.bpm(120.0);
      final branch = Branch(
        input: clock.trigger,
        weights: const [0.6, 0.25, 0.15],
      );

      expect(branch.count, equals(3));
      expect(branch.outlets, hasLength(3));
      expect(branch[0], equals(branch.outlets[0]));
      expect(branch[2], equals(branch.outlets[2]));
      expect(branch.errors, isEmpty);

      final uniform = Branch.uniform(input: clock.trigger, count: 4);
      expect(uniform.count, equals(4));
      expect(uniform.errors, isEmpty);

      expect(
        Branch(input: clock.trigger, weights: const []).errors,
        isNotEmpty,
      );
      expect(
        Branch(input: clock.trigger, weights: const [0.0, 0.0]).errors,
        isNotEmpty,
      );
      expect(
        Branch(input: clock.trigger, weights: const [1.0, -0.5]).errors,
        isNotEmpty,
      );
      expect(
        Branch(
          input: clock.trigger,
          weights: const [1.0, 1.0],
          maxConsecutive: 0,
        ).errors,
        isNotEmpty,
      );
    });

    test('routes weighted distribution accurately across outlets', () {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final proc = BranchProcessor(
        weights: const [60.0, 30.0, 10.0],
        seed: 12345,
      );

      final input = Float32List(64);
      final outputs = List.generate(3, (_) => Float32List(64));
      final counts = [0, 0, 0];

      // Fire 2000 single-sample triggers (every other sample).
      for (int block = 0; block < 63; block++) {
        for (int i = 0; i < 64; i++) {
          input[i] = i.isEven ? 1.0 : 0.0;
        }
        proc.process(context, [input], outputs);
        for (int i = 0; i < 64; i += 2) {
          int activeCount = 0;
          for (int ch = 0; ch < 3; ch++) {
            if (outputs[ch][i] > 0.0) {
              counts[ch]++;
              activeCount++;
            }
          }
          expect(activeCount, equals(1));
        }
      }

      final total = counts[0] + counts[1] + counts[2];
      expect(counts[0] / total, closeTo(0.60, 0.04));
      expect(counts[1] / total, closeTo(0.30, 0.04));
      expect(counts[2] / total, closeTo(0.10, 0.03));
    });

    test('enforces maxConsecutive: 1 (no repeats) and maxConsecutive: 2', () {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);

      for (final maxConsec in [1, 2]) {
        final proc = BranchProcessor(
          weights: const [0.8, 0.1, 0.1],
          maxConsecutive: maxConsec,
          seed: 99,
        );

        final input = Float32List(64);
        final outputs = List.generate(3, (_) => Float32List(64));
        int lastBranch = -1;
        int streak = 0;

        for (int block = 0; block < 20; block++) {
          for (int i = 0; i < 64; i++) {
            input[i] = i.isEven ? 1.0 : 0.0;
          }
          proc.process(context, [input], outputs);
          for (int i = 0; i < 64; i += 2) {
            int chosen = -1;
            for (int ch = 0; ch < 3; ch++) {
              if (outputs[ch][i] > 0.0) chosen = ch;
            }
            expect(chosen, greaterThanOrEqualTo(0));
            if (chosen == lastBranch) {
              streak++;
            } else {
              lastBranch = chosen;
              streak = 1;
            }
            expect(streak, lessThanOrEqualTo(maxConsec));
          }
        }
      }
    });

    test('latches sustained gates and preserves velocity values', () {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 16);
      final proc = BranchProcessor(weights: const [1.0, 1.0], seed: 7);

      final input = Float32List(16);
      // Gate high from sample 2..9 with varying velocity values.
      for (int i = 2; i < 10; i++) {
        input[i] = 0.75;
      }
      final outputs = List.generate(2, (_) => Float32List(16));
      proc.process(context, [input], outputs);

      final chosen = outputs[0][2] > 0.0 ? 0 : 1;
      final other = 1 - chosen;
      for (int i = 2; i < 10; i++) {
        expect(outputs[chosen][i], closeTo(0.75, 1e-6));
        expect(outputs[other][i], equals(0.0));
      }
      expect(outputs[chosen][0], equals(0.0));
      expect(outputs[chosen][10], equals(0.0));
    });

    test('supports in-place dynamic weight updates via AudioHost', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 16);
      final host = SyncAudioHost(context: context);
      final clock = Clock.bpm(120.0);
      final branch = Branch(
        input: clock.trigger,
        weights: const [1.0, 0.0],
        seed: 1,
      );
      expect(
        host.setGraph(
          root: Out.stereo(left: branch[0], right: branch[1]),
        ),
        isEmpty,
      );

      final b1 = await host.renderBlocks(1);
      expect(b1[0][0], equals(1.0)); // routed exclusively to 0
      expect(b1[1][0], equals(0.0));

      // Flip weights in-place to route exclusively to 1.
      host.update(branch, (weights: const [0.0, 1.0], maxConsecutive: null));
      final proc = host.processorOf<BranchProcessor>(branch)!;
      final inp = Float32List(16)..[0] = 1.0;
      final outs = [Float32List(16), Float32List(16)];
      proc.process(context, [inp], outs);
      expect(outs[0][0], equals(0.0));
      expect(outs[1][0], equals(1.0));

      await host.dispose();
    });
  });
}
