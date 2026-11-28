import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('PitchDetector (YIN)', () {
    test('declares expected inlet, outlets, and parameter validation', () {
      final osc = SineOscillator(frequency: const .value(440));
      final pitch = PitchDetector(input: osc.outlet);

      expect(pitch.inlets, hasLength(1));
      expect(pitch.inlets[0].source, equals(osc.outlet));
      expect(pitch.outlets, hasLength(4));
      expect(pitch.audio, equals(pitch.outlets[0]));
      expect(pitch.frequency, equals(pitch.outlets[1]));
      expect(pitch.gate, equals(pitch.outlets[2]));
      expect(pitch.clarity, equals(pitch.outlets[3]));
      expect(pitch.errors, isEmpty);

      final invalid = PitchDetector(
        input: osc.outlet,
        windowSize: 0,
        hopSize: -1,
        minFrequency: 500.0,
        maxFrequency: 200.0,
        threshold: 1.5,
        minRms: -0.1,
        a4: 0.0,
      );
      expect(invalid.errors, hasLength(6));
    });

    test('tracks 440 Hz sine wave with sub-cent accuracy', () {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final osc = SineOscillator(frequency: const .value(440.0));
      final pitch = PitchDetector(input: osc.outlet);

      final pipeline = compilePipeline(root: pitch, context: context).pipeline!;
      final proc = pipeline.processorOf(pitch);

      for (int i = 0; i < 45; i++) {
        pipeline.process();
      }

      expect(proc.isPitched, isTrue);
      expect(proc.frequency, closeTo(440.0, 0.25)); // < 1 cent at 440 Hz
      expect(proc.clarity, greaterThan(0.98));

      // Verify all 4 outlets.
      expect(pipeline.outputs[1][0], closeTo(440.0, 0.25));
      expect(pipeline.outputs[2][0], equals(1.0));
      expect(pipeline.outputs[3][0], greaterThan(0.98));
    });

    test(
      'tracks guitar Low E (82.41 Hz) with strong H2 > H1 without octave error',
      () {
        const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
        final lowE = Note.parse('E2').hz; // 82.4069 Hz

        // Guitar-like harmonic mix where H2 (2 * f0) is 2x louder than H1 (f0).
        final h1 = Mult.mono(
          input: SineOscillator(frequency: .value(lowE)).outlet,
          value: const .value(0.3),
        );
        final h2 = Mult.mono(
          input: SineOscillator(frequency: .value(lowE * 2.0)).outlet,
          value: const .value(0.6),
        );
        final h3 = Mult.mono(
          input: SineOscillator(frequency: .value(lowE * 3.0)).outlet,
          value: const .value(0.2),
        );
        final mix = Sum(inputs: [h1.outlet, h2.outlet, h3.outlet]);
        final pitch = PitchDetector(
          input: mix.outlet,
          windowSize: 1024,
          hopSize: 256,
          minFrequency: 50.0,
          maxFrequency: 1000.0,
        );

        final pipeline = compilePipeline(
          root: pitch,
          context: context,
        ).pipeline!;
        final proc = pipeline.processorOf(pitch);

        for (int i = 0; i < 45; i++) {
          pipeline.process();
        }

        expect(proc.isPitched, isTrue);
        // Must lock onto E2 (~82.41 Hz), NOT E3 (~164.81 Hz)!
        expect(proc.frequency, closeTo(lowE, 0.2));
        expect(proc.clarity, greaterThan(0.95));
      },
    );

    test('tracks high frequency (880 Hz) with parabolic sub-sample accuracy', () {
      // At 44.1 kHz, 880 Hz has period 50.1136 samples; integer lag 50 would
      // give 882.0 Hz (~4 cents sharp). Parabolic interpolation gets < 1 cent.
      const context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final osc = SineOscillator(frequency: const .value(880.0));
      final pitch = PitchDetector(input: osc.outlet);

      final pipeline = compilePipeline(root: pitch, context: context).pipeline!;
      final proc = pipeline.processorOf(pitch);

      for (int i = 0; i < 45; i++) {
        pipeline.process();
      }

      expect(proc.isPitched, isTrue);
      expect(proc.frequency, closeTo(880.0, 0.5));
    });

    test('gates silence and unpitched noise while holding frequency CV', () {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final proc = PitchDetectorProcessor(
        windowSize: 512,
        hopSize: 128,
        minFrequency: 80.0,
        maxFrequency: 1000.0,
      );

      final oscProc = SineOscillatorProcessor(frequency: 330.0);
      final audioBuf = Float32List(64);
      final outAudio = Float32List(64);
      final outFreq = Float32List(64);
      final outGate = Float32List(64);
      final outClarity = Float32List(64);
      final outputs = [outAudio, outFreq, outGate, outClarity];

      // Feed 330 Hz tone until locked.
      for (int i = 0; i < 30; i++) {
        oscProc.process(context, const [], [audioBuf]);
        proc.process(context, [audioBuf], outputs);
      }
      expect(proc.isPitched, isTrue);
      expect(proc.frequency, closeTo(330.0, 0.5));
      expect(outGate[0], equals(1.0));
      expect(outFreq[0], closeTo(330.0, 0.5));

      // Feed silence -> gate drops to 0.0, telemetry frequency = 0.0,
      // but frequency CV holds ~330 Hz!
      audioBuf.fillRange(0, 64, 0.0);
      for (int i = 0; i < 30; i++) {
        proc.process(context, [audioBuf], outputs);
      }
      expect(proc.isPitched, isFalse);
      expect(proc.frequency, equals(0.0));
      final heldAfterSilence = proc.heldFrequency;
      expect(heldAfterSilence, closeTo(330.0, 5.0));
      expect(outGate[0], equals(0.0));
      expect(outClarity[0], equals(0.0));
      expect(outFreq[0], closeTo(heldAfterSilence, 1e-4));

      // Feed white noise -> should remain unpitched and keep holding frequency.
      final rng = math.Random(42);
      for (int i = 0; i < 30; i++) {
        for (int s = 0; s < 64; s++) {
          audioBuf[s] = rng.nextDouble() * 2.0 - 1.0;
        }
        proc.process(context, [audioBuf], outputs);
      }
      expect(proc.isPitched, isFalse);
      expect(outGate[0], equals(0.0));
      expect(proc.heldFrequency, equals(heldAfterSilence));
    });

    test('streams PitchReading telemetry with note and cents through SyncAudioHost', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(
        context: context,
        telemetryInterval: const Duration(milliseconds: 10),
      );

      // A4 sharp by +10 cents: 440 * 2^(10/1200) ~= 442.549 Hz.
      final targetHz = midiToHz(69.10);
      final osc = SineOscillator(frequency: .value(targetHz));
      final pitch = osc.outlet.pitchDetector();
      final out = Out.mono(pitch.audio);

      expect(host.setGraph(root: out), isEmpty);

      final channel = host.telemetryOf(pitch)!;
      final readings = <PitchReading>[];
      final sub = channel.stream.listen(readings.add);

      await host.renderBlocks(60);
      await Future<void>.delayed(Duration.zero);

      expect(readings, isNotEmpty);
      final last = readings.last;
      expect(last.hasPitch, isTrue);
      expect(last.frequency, closeTo(targetHz, 0.3));
      expect(last.note?.name, equals('A4'));
      expect(last.cents, closeTo(10.0, 1.5));
      expect(last.clarity, greaterThan(0.98));

      await sub.cancel();
      await host.dispose();
    });

    test('supports dynamic update of threshold and minRms', () {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final osc = SineOscillator(frequency: const .value(440.0));
      final quiet = Mult.mono(input: osc.outlet, value: const .value(0.02));
      final pitch = PitchDetector(
        input: quiet.outlet,
        minRms: 0.05, // blocks 0.02 amplitude signal (~0.014 RMS)
      );

      final pipeline = compilePipeline(root: pitch, context: context).pipeline!;
      final proc = pipeline.processorOf(pitch);

      for (int i = 0; i < 45; i++) {
        pipeline.process();
      }
      expect(proc.isPitched, isFalse);

      // Lower minRms in place -> now detects 440 Hz without graph rebuild.
      proc.update((threshold: null, minRms: 0.005));
      for (int i = 0; i < 10; i++) {
        pipeline.process();
      }
      expect(proc.isPitched, isTrue);
      expect(proc.frequency, closeTo(440.0, 0.5));
    });
  });
}
