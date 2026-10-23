import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('StepSequencer', () {
    test('declares expected inlets and outlets', () {
      final clock = Clock(frequency: const .value(4));
      final reset = Clock(frequency: const .value(1));
      final seq = StepSequencer(
        clock: clock.trigger,
        reset: reset.trigger,
        steps: const .value([100.0, 200.0, 300.0]),
      );

      expect(seq.inlets.length, equals(2));
      expect(
        seq.inlets[StepSequencer.clockInlet].source,
        equals(clock.trigger),
      );
      expect(
        seq.inlets[StepSequencer.resetInlet].source,
        equals(reset.trigger),
      );

      expect(seq.outlets.length, equals(1));
      expect(seq.cv, equals(seq.outlets.first));
      expect(seq.outlet, equals(seq.cv));
    });

    test('StepSequencer.fromList sets values and params correctly', () {
      final clock = Clock(frequency: const .value(4));
      final seq = StepSequencer.fromList(
        clock: clock.trigger,
        steps: [1.0, 2.0, 3.0, 4.0],
      );

      expect(seq.params.steps, equals([1.0, 2.0, 3.0, 4.0]));
      expect(seq.params.threshold, equals(0.5));
      expect(seq.params.hasReset, isFalse);
    });

    test(
      'StepSequencer.notes and StepSequencer.sequence parse note pitches',
      () {
        final clock = Clock(frequency: const .value(4));

        final seqNotes = StepSequencer.notes(
          clock: clock.trigger,
          notes: ['A3', 'C4', 'E4', 'A4'],
        );
        expect(seqNotes.params.steps[0], equals(220.0));
        expect(seqNotes.params.steps[1], closeTo(261.63, 0.01));
        expect(seqNotes.params.steps[3], equals(440.0));

        final seqString = StepSequencer.sequence(
          clock: clock.trigger,
          sequence: 'A3 C4 E4 A4',
        );
        expect(seqString.params.steps, equals(seqNotes.params.steps));
      },
    );

    test(
      'steps sequentially through values on rising clock edges and loops',
      () {
        final processor = StepSequencerProcessor(
          steps: [10.0, 20.0, 30.0],
          threshold: 0.5,
          hasReset: false,
        );

        final context = ProcessContext(sampleRate: 100, vectorSize: 6);

        // Block 1:
        // sample 0: clock high (1st pulse -> step 0)
        // sample 1: clock high (gate held, no step advance)
        // sample 2: clock low
        // sample 3: clock high (2nd pulse -> step 1)
        // sample 4: clock low
        // sample 5: clock high (3rd pulse -> step 2)
        final clockBuf = Float32List.fromList([1.0, 1.0, 0.0, 1.0, 0.0, 1.0]);
        final emptyReset = Float32List(6);
        final cvOut = Float32List(6);

        processor.process(
          context,
          [clockBuf, emptyReset],
          [cvOut],
        );

        // Step values:
        expect(cvOut[0], equals(10.0));
        expect(cvOut[1], equals(10.0));
        expect(cvOut[2], equals(10.0));
        expect(cvOut[3], equals(20.0));
        expect(cvOut[4], equals(20.0));
        expect(cvOut[5], equals(30.0));

        // Block 2: 4th pulse wraps back to step 0 (10.0)
        final clockBuf2 = Float32List.fromList([0.0, 1.0, 0.0, 0.0, 0.0, 0.0]);
        processor.process(
          context,
          [clockBuf2, emptyReset],
          [cvOut],
        );

        expect(cvOut[0], equals(30.0)); // held from previous block
        expect(cvOut[1], equals(10.0)); // wrapped to step 0
      },
    );

    test('resets immediately to step 0 when reset rises', () {
      final processor = StepSequencerProcessor(
        steps: [100.0, 200.0, 300.0, 400.0],
        threshold: 0.5,
        hasReset: true,
      );

      final context = ProcessContext(sampleRate: 100, vectorSize: 6);

      // Advance to step 1 (200.0) on clock pulses
      final clockBuf = Float32List.fromList([1.0, 0.0, 1.0, 0.0, 0.0, 0.0]);
      final resetBuf = Float32List.fromList([0.0, 0.0, 0.0, 0.0, 1.0, 0.0]);
      final cvOut = Float32List(6);

      processor.process(
        context,
        [clockBuf, resetBuf],
        [cvOut],
      );

      expect(cvOut[0], equals(100.0)); // 1st pulse -> step 0
      expect(cvOut[2], equals(200.0)); // 2nd pulse -> step 1
      expect(
        cvOut[4],
        equals(100.0),
      ); // reset rises on sample 4 -> back to step 0
    });

    test('handles empty steps gracefully without throwing', () {
      final processor = StepSequencerProcessor(steps: []);
      final context = ProcessContext(sampleRate: 100, vectorSize: 4);

      final clockBuf = Float32List.fromList([1.0, 0.0, 1.0, 0.0]);
      final resetBuf = Float32List(4);
      final cvOut = Float32List(4);

      expect(
        () => processor.process(
          context,
          [clockBuf, resetBuf],
          [cvOut],
        ),
        returnsNormally,
      );

      expect(cvOut, equals([0.0, 0.0, 0.0, 0.0]));
    });

    test('stepSequencer extension creates valid StepSequencer node', () {
      final clock = Clock(frequency: const .value(2));
      final seq = clock.trigger.stepSequencer(steps: [440.0, 880.0]);

      expect(seq, isA<StepSequencer>());
      expect(
        seq.inlets[StepSequencer.clockInlet].source,
        equals(clock.trigger),
      );
      expect(seq.params.steps, equals([440.0, 880.0]));
    });

    test(
      'compiles and executes inside AudioPipeline with live pattern updates',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final clock = Clock(frequency: const .value(1000));
        final seq = StepSequencer.fromList(
          clock: clock.trigger,
          steps: [220.0, 440.0, 880.0],
        );
        final saw = SawtoothOscillator(frequency: .signal(seq.cv));

        final pipeline = compilePipeline(root: saw, context: context).pipeline!;
        pipeline.process();
        expect(pipeline.outputs.first.length, equals(64));

        // Live update sequence
        pipeline.update(
          seq,
          StepSequencer.fromList(
            clock: clock.trigger,
            steps: [110.0, 330.0],
          ),
        );
        pipeline.process();
        expect(pipeline.outputs.first.length, equals(64));
      },
    );
  });
}
