import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Swarm composite', () {
    test('instantiates expected number of oscillators and panners', () {
      final swarm = Swarm.sawtooth(
        frequency: const .value(110.0),
        voices: 7,
        detuneCents: 20.0,
        stereoSpread: 0.8,
      );

      expect(swarm.oscillators.length, equals(7));
      expect(swarm.panners.length, equals(7));
      expect(swarm.left, isA<Outlet>());
      expect(swarm.right, isA<Outlet>());
      expect(swarm.outlet, isA<Outlet>());

      for (final osc in swarm.oscillators) {
        expect(osc, isA<SawtoothOscillator>());
      }
    });

    test('supports different waveform factories', () {
      final sineSwarm = Swarm.sine(
        frequency: const .value(220.0),
        voices: 5,
      );
      expect(sineSwarm.oscillators.first, isA<SineOscillator>());

      final triSwarm = Swarm.triangle(
        frequency: const .value(220.0),
        voices: 5,
      );
      expect(triSwarm.oscillators.first, isA<TriangleOscillator>());

      final sqSwarm = Swarm.square(
        frequency: const .value(220.0),
        voices: 5,
      );
      expect(sqSwarm.oscillators.first, isA<SquareOscillator>());
    });

    test('single voice swarm centers pitch and pan', () {
      final swarm = Swarm.sawtooth(
        frequency: const .value(440.0),
        voices: 1,
      );

      expect(swarm.oscillators.length, equals(1));
      expect(swarm.panners.length, equals(1));
      expect(
        swarm.oscillators.first.frequency.valueOrNull,
        closeTo(440.0, 1e-4),
      );
      expect(swarm.panners.first.pan.valueOrNull, equals(0.0));
    });

    test('distributes detune and pan symmetrically around center', () {
      final swarm = Swarm.sawtooth(
        frequency: const .value(100.0),
        voices: 5,
        detuneCents: 20.0,
        stereoSpread: 0.8,
      );

      // Center voice (index 2 for 5 voices)
      expect(swarm.oscillators[2].frequency.valueOrNull, closeTo(100.0, 1e-4));
      expect(swarm.panners[2].pan.valueOrNull, equals(0.0));

      // Left-most voice (index 0)
      final leftFreq = swarm.oscillators[0].frequency.valueOrNull!;
      final leftPan = swarm.panners[0].pan.valueOrNull!;
      expect(leftFreq, lessThan(100.0));
      expect(leftPan, closeTo(-0.8, 1e-4));

      // Right-most voice (index 4)
      final rightFreq = swarm.oscillators[4].frequency.valueOrNull!;
      final rightPan = swarm.panners[4].pan.valueOrNull!;
      expect(rightFreq, greaterThan(100.0));
      expect(rightPan, closeTo(0.8, 1e-4));

      // Symmetrical ratios
      final leftRatio = leftFreq / 100.0;
      final rightRatio = rightFreq / 100.0;
      expect(leftRatio * rightRatio, closeTo(1.0, 1e-3));
    });

    test('renders non-silent audio in AudioPipeline', () {
      final swarm = Swarm.sawtooth(
        frequency: const .value(110.0),
        voices: 5,
      );

      final sum = Sum.pair(swarm.left, swarm.right);
      final context = ProcessContext(sampleRate: 44100, vectorSize: 256);
      final pipeline = compilePipeline(root: sum, context: context).pipeline!;

      pipeline.process();
      final output = pipeline.outputs[0];

      expect(output.length, equals(256));
      expect(output.any((s) => s != 0.0), isTrue);

      // Verify bounds (left <= 1.0, right <= 1.0 -> sum <= 2.0)
      for (final s in output) {
        expect(s.abs(), lessThanOrEqualTo(2.0));
      }
    });

    test('stereo channels exhibit acoustic beating decorrelation', () {
      final swarm = Swarm.sawtooth(
        frequency: const .value(110.0),
        voices: 7,
        detuneCents: 25.0,
        stereoSpread: 0.9,
      );

      final context = ProcessContext(sampleRate: 44100, vectorSize: 512);
      final pipelineL = compilePipeline(
        root: swarm.left.node,
        context: context,
      ).pipeline!;
      final pipelineR = compilePipeline(
        root: swarm.right.node,
        context: context,
      ).pipeline!;

      pipelineL.process();
      pipelineR.process();

      final outL = pipelineL.outputs[0];
      final outR = pipelineR.outputs[0];

      expect(outL, isNot(equals(outR)));
    });

    test('supports audio-rate frequency modulation signal', () {
      final lfo = SineOscillator(frequency: const .value(2.0));
      final modFreq = lfo.mapRange(100.0, 200.0);

      final swarm = Swarm.sawtooth(
        frequency: .signal(modFreq.outlet),
        voices: 3,
      );

      final sum = Sum.pair(swarm.left, swarm.right);
      final context = ProcessContext(sampleRate: 44100, vectorSize: 128);
      final pipeline = compilePipeline(root: sum, context: context).pipeline!;

      pipeline.process();
      expect(pipeline.outputs[0].any((s) => s != 0.0), isTrue);
    });

    test(
      'in-place parameter update preserves processors and phase continuity',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 128);
        final engine = AudioEngine(context: context);

        final swarm1 = Swarm.sawtooth(
          frequency: const .value(110.0),
          voices: 5,
        );
        final sum1 = Sum.pair(swarm1.left, swarm1.right);
        final snapshot1 = compileGraph(root: sum1).snapshot!;
        final diff1 = diffGraph(GraphSnapshot.empty, snapshot1);
        engine.applyDiff(diff1);

        final firstOsc = swarm1.oscillators[0];
        final oscId = diff1.snapshot.nodeIds[firstOsc]!;
        final processorBefore = engine.processorOf<SawtoothOscillatorProcessor>(
          oscId,
        )!;

        // Render block 1
        engine.process();
        final phaseAfterBlock1 = processorBefore.phase;
        expect(
          processorBefore.frequency,
          closeTo(firstOsc.frequency.valueOrNull!, 1e-4),
        );

        // Update to new frequency
        final swarm2 = Swarm.sawtooth(
          frequency: const .value(220.0),
          voices: 5,
        );
        final sum2 = Sum.pair(swarm2.left, swarm2.right);
        final snapshot2 = compileGraph(root: sum2).snapshot!;
        final diff2 = diffGraph(diff1.snapshot, snapshot2);

        expect(diff2.hasScheduleChange, isFalse);
        expect(diff2.addedNodes.isEmpty, isTrue);
        expect(diff2.removedNodeIds.isEmpty, isTrue);
        expect(diff2.updatedParams.isNotEmpty, isTrue);

        expect(diff2.addedNodes.isEmpty, isTrue);
        expect(diff2.removedNodeIds.isEmpty, isTrue);
        expect(diff2.updatedParams.isNotEmpty, isTrue);
        engine.applyDiff(diff2);

        // Processor should be preserved in-place, frequency updated
        expect(
          processorBefore.frequency,
          closeTo(swarm2.oscillators[0].frequency.valueOrNull!, 1e-4),
        );
        expect(processorBefore.phase, equals(phaseAfterBlock1));
      },
    );

    test('Note.swarm extension builds swarm on note pitch', () {
      final note = Note.parse('D2');
      final swarm = note.swarm(voices: 5, detuneCents: 18.0);

      expect(swarm.oscillators.length, equals(5));
      expect(
        swarm.oscillators[2].frequency.valueOrNull,
        closeTo(note.hz, 1e-4),
      );
    });
  });
}
