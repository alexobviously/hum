import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Decay node', () {
    test('declares expected inlets and outlets', () {
      final clock = Clock.bpm(120);
      final decay = Decay(
        trigger: clock.trigger,
        decay: const .value(0.1),
        attack: const .value(0.01),
      );

      expect(decay.inlets.length, equals(1));
      expect(decay.inlets[Decay.triggerInlet].source, equals(clock.trigger));
      expect(decay.outlets.length, equals(1));
      expect(decay.outlet, equals(decay.outlets.first));
    });

    test('factories Decay.pure and Decay.ar configure expected params', () {
      final clock = Clock.bpm(120);
      final pureDecay = Decay.pure(
        trigger: clock.trigger,
        time: const .value(0.2),
      );
      expect(pureDecay.params.attack, equals(0.0));
      expect(pureDecay.params.decay, equals(0.2));

      final arEnvelope = Decay.ar(
        trigger: clock.trigger,
        attack: const .value(0.02),
        decay: const .value(0.15),
      );
      expect(arEnvelope.params.attack, equals(0.02));
      expect(arEnvelope.params.decay, equals(0.15));
    });

    test('stays idle at 0.0 when no trigger occurs', () {
      final clock = Clock.bpm(120);
      final decay = Decay(trigger: clock.trigger);
      final processor = decay.createProcessor();

      const vectorSize = 32;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      final inputs = [Float32List(vectorSize)];
      final outputs = [Float32List(vectorSize)];

      processor.process(context, inputs, outputs);

      for (int i = 0; i < vectorSize; i++) {
        expect(outputs[0][i], equals(0.0));
      }
      expect(processor.state, equals(DecayState.idle));
    });

    test('instant attack outputs 1.0 immediately on trigger and decays exponentially', () {
      const sampleRate = 1000;
      const vectorSize = 100;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final clock = Clock.bpm(120);
      final decay = Decay(
        trigger: clock.trigger,
        decay: const .value(0.05), // 50 samples
        attack: const .value(0.0), // Instant attack
        curve: DecayCurve.exponential,
      );
      final processor = decay.createProcessor();

      // Trigger impulse at index 10
      final triggerBuf = Float32List(vectorSize);
      triggerBuf[10] = 1.0;

      final outputs = [Float32List(vectorSize)];
      processor.process(context, [triggerBuf], outputs);

      final out = outputs[0];

      // Before trigger: idle at 0.0
      expect(out[9], equals(0.0));

      // At trigger sample 10: instant 1.0 output
      expect(out[10], equals(1.0));

      // After trigger: decaying
      expect(out[11], lessThan(1.0));
      expect(out[11], greaterThan(0.8));

      // At sample 60 (10 + 50 samples): should be close to 0.0
      expect(out[60], lessThan(0.05));
      expect(out[95], equals(0.0));
      expect(processor.state, equals(DecayState.idle));
    });

    test('linear decay ramps down at a constant rate', () {
      const sampleRate = 1000;
      const vectorSize = 100;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final clock = Clock.bpm(120);
      final decay = Decay(
        trigger: clock.trigger,
        decay: const .value(0.04), // 40 samples
        attack: const .value(0.0),
        curve: DecayCurve.linear,
      );
      final processor = decay.createProcessor();

      final triggerBuf = Float32List(vectorSize);
      triggerBuf[0] = 1.0;

      final outputs = [Float32List(vectorSize)];
      processor.process(context, [triggerBuf], outputs);

      final out = outputs[0];
      expect(out[0], equals(1.0));

      // Halfway through (20 samples): should be ~0.5
      expect(out[20], closeTo(0.5, 0.03));

      // End of decay (40 samples): should hit 0.0
      expect(out[40], equals(0.0));
      expect(out[50], equals(0.0));
      expect(processor.state, equals(DecayState.idle));
    });

    test('attack > 0 ramps up smoothly before decaying', () {
      const sampleRate = 1000;
      const vectorSize = 100;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final clock = Clock.bpm(120);
      final decay = Decay(
        trigger: clock.trigger,
        attack: const .value(0.02), // 20 samples
        decay: const .value(0.04), // 40 samples
        curve: DecayCurve.linear,
      );
      final processor = decay.createProcessor();

      final triggerBuf = Float32List(vectorSize);
      triggerBuf[10] = 1.0;

      final outputs = [Float32List(vectorSize)];
      processor.process(context, [triggerBuf], outputs);

      final out = outputs[0];
      expect(out[9], equals(0.0));

      // Attack phase: starts ramping up from sample 10, peaks around sample 29
      expect(out[10], greaterThan(0.0));
      expect(out[19], closeTo(0.5, 0.02));
      expect(out[29], closeTo(1.0, 0.02));

      // Decay phase: peaks at 1.0 and decays down to 0.0 around sample 70
      expect(out[50], closeTo(0.5, 0.05));
      expect(out[70], equals(0.0));
      expect(processor.state, equals(DecayState.idle));
    });

    test(
      'ignores held gates and completes decay regardless of gate length',
      () {
        const sampleRate = 1000;
        const vectorSize = 100;
        final context = ProcessContext(
          sampleRate: sampleRate,
          vectorSize: vectorSize,
        );

        final clock = Clock.bpm(120);
        final decay = Decay(
          trigger: clock.trigger,
          decay: const .value(0.02), // 20 samples
          curve: DecayCurve.linear,
        );
        final processor = decay.createProcessor();

        // Long gate signal held high for 60 samples
        final heldGate = Float32List(vectorSize);
        for (int i = 0; i < 60; i++) {
          heldGate[i] = 1.0;
        }

        final outputs = [Float32List(vectorSize)];
        processor.process(context, [heldGate], outputs);

        final out = outputs[0];

        // Fires on rising edge at sample 0
        expect(out[0], equals(1.0));

        // Even though gate is still 1.0 at sample 25, the decay envelope has reached 0.0!
        expect(out[20], equals(0.0));
        expect(out[30], equals(0.0));
        expect(out[50], equals(0.0));
        expect(processor.state, equals(DecayState.idle));
      },
    );

    test('retriggers cleanly mid-flight', () {
      const sampleRate = 1000;
      const vectorSize = 100;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final clock = Clock.bpm(120);
      final decay = Decay(
        trigger: clock.trigger,
        decay: const .value(0.05), // 50 samples
        curve: DecayCurve.linear,
      );
      final processor = decay.createProcessor();

      final triggerBuf = Float32List(vectorSize);
      triggerBuf[0] = 1.0; // First hit
      triggerBuf[20] =
          1.0; // Retrigger at sample 20 while still decaying (~0.6)

      final outputs = [Float32List(vectorSize)];
      processor.process(context, [triggerBuf], outputs);

      final out = outputs[0];
      expect(out[0], equals(1.0));
      expect(out[19], closeTo(0.62, 0.02));

      // Retrigger resets to 1.0
      expect(out[20], equals(1.0));
      expect(out[21], lessThan(1.0));
    });

    test(
      'compiles and executes inside AudioPipeline with live parameter updates',
      () {
        final clock = Clock.bpm(120);
        final decay = Decay(trigger: clock.trigger, decay: const .value(0.1));

        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final pipeline = compilePipeline(
          root: decay,
          context: context,
        ).pipeline!;
        pipeline.process();
        expect(pipeline.outputs.length, equals(1));
        expect(pipeline.outputs[0].length, equals(64));

        // Update decay parameter on the fly using a new node spec
        pipeline.update(
          decay,
          Decay(
            trigger: clock.trigger,
            decay: const .value(0.25),
            attack: const .value(0.01),
            curve: DecayCurve.linear,
          ),
        );
        pipeline.process();
        expect(pipeline.outputs[0].length, equals(64));
      },
    );

    test('Outlet.decay extension syntax constructs Decay node', () {
      final clock = Clock.bpm(120);
      final decay = clock.trigger.decay(0.05, 0.005, DecayCurve.linear);

      expect(decay, isA<Decay>());
      expect(decay.params.decay, equals(0.05));
      expect(decay.params.attack, equals(0.005));
      expect(decay.params.curve, equals(DecayCurve.linear));
    });
  });
}
