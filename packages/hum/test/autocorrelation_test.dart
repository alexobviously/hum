import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Autocorrelation', () {
    test('declares expected inlet and passthrough outlet', () {
      final osc = SineOscillator(frequency: const .value(440));
      final autocorr = Autocorrelation(input: osc.outlet);

      expect(autocorr.inlets.length, equals(1));
      expect(autocorr.inlets[0].source, equals(osc.outlet));
      expect(autocorr.outlets.length, equals(1));
      expect(autocorr.outlet, equals(autocorr.outlets[0]));
    });

    test('detects 440 Hz sine wave (lag ~100 samples)', () {
      const sampleRate = 44100;
      const vectorSize = 128;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final osc = SineOscillator(frequency: const .value(440.0));
      final autocorr = Autocorrelation(
        input: osc.outlet,
        windowSize: 1024,
        hopSize: 256,
      );

      final pipeline = compilePipeline(
        root: autocorr,
        context: context,
      ).pipeline!;
      final proc = pipeline.processorOf(autocorr);

      // Process blocks to fill the analysis window
      for (int i = 0; i < 20; i++) {
        pipeline.process();
      }

      // At 44.1 kHz, 440 Hz has a period of 44100 / 440 = 100.22 samples
      expect(proc.bestLag, equals(100));
      expect(proc.frequency, closeTo(441.0, 2.0));
      expect(proc.maxCorrelation, greaterThan(0.0));
    });

    test('detects guitar Low E (~82.4 Hz, lag ~535 samples)', () {
      const sampleRate = 44100;
      const vectorSize = 128;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final lowE = Note.parse('E2').hz; // 82.41 Hz
      final osc = SineOscillator(frequency: .value(lowE));
      final autocorr = Autocorrelation(
        input: osc.outlet,
        minFrequency: 60.0,
        windowSize: 1024,
        hopSize: 256,
      );

      final pipeline = compilePipeline(
        root: autocorr,
        context: context,
      ).pipeline!;
      final proc = pipeline.processorOf(autocorr);

      for (int i = 0; i < 25; i++) {
        pipeline.process();
      }

      // 44100 / 82.4068 = 535.15 samples (unnormalized integer lag within ~3 samples)
      expect(proc.bestLag, closeTo(535, 4));
      expect(proc.frequency, closeTo(82.4, 1.0));
    });

    test('passes input audio through to output buffer', () {
      const sampleRate = 44100;
      const vectorSize = 64;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final osc = SineOscillator(frequency: const .value(440));
      final autocorr = Autocorrelation(input: osc.outlet);

      final pipeline = compilePipeline(
        root: autocorr,
        context: context,
      ).pipeline!;
      pipeline.process();

      final out = pipeline.outputs[0];
      bool hasNonZero = false;
      for (int s = 0; s < vectorSize; s++) {
        if (out[s].abs() > 0.01) {
          hasNonZero = true;
          break;
        }
      }
      expect(hasNonZero, isTrue);
    });

    test('writeTelemetry emits only after a new hop completes', () {
      const context = ProcessContext(sampleRate: 44100, vectorSize: 128);
      final osc = SineOscillator(frequency: const .value(440.0));
      final autocorr = Autocorrelation(
        input: osc.outlet,
        windowSize: 1024,
        hopSize: 256,
      );

      final pipeline = compilePipeline(
        root: autocorr,
        context: context,
      ).pipeline!;
      final proc = pipeline.processorOf(autocorr);
      final buf = Float32List(proc.telemetryLength);

      // Before any hop completes, nothing to emit.
      expect(proc.writeTelemetry(buf, 0), isFalse);
      pipeline.process(); // 128 < 256
      expect(proc.writeTelemetry(buf, 0), isFalse);

      // Run enough blocks to fill window and trigger correlation.
      for (int i = 0; i < 19; i++) {
        pipeline.process();
      }
      expect(proc.writeTelemetry(buf, 0), isTrue);

      final reading = autocorr.decodeTelemetry(buf);
      expect(reading.hasPitch, isTrue);
      expect(reading.bestLag, equals(100));
      expect(reading.frequency, closeTo(441.0, 2.0));
      expect(reading.maxCorrelation, greaterThan(0.0));

      // Second flush without another hop returns false.
      expect(proc.writeTelemetry(buf, 0), isFalse);
    });

    test('streams AutocorrelationReading telemetry through SyncAudioHost', () async {
      const context = ProcessContext(sampleRate: 44100, vectorSize: 128);
      final host = SyncAudioHost(
        context: context,
        telemetryInterval: const Duration(milliseconds: 10),
      );

      final osc = SineOscillator(frequency: const .value(440.0));
      final autocorr = Autocorrelation(
        input: osc.outlet,
        windowSize: 1024,
        hopSize: 256,
      );
      final out = Out.mono(autocorr.outlet);

      expect(host.setGraph(root: out), isEmpty);

      final channel = host.telemetryOf(autocorr)!;
      final readings = <AutocorrelationReading>[];
      final sub = channel.stream.listen(readings.add);

      await host.renderBlocks(25);
      await Future<void>.delayed(Duration.zero);

      expect(readings, isNotEmpty);
      final last = readings.last;
      expect(last.hasPitch, isTrue);
      expect(last.bestLag, equals(100));
      expect(last.frequency, closeTo(441.0, 2.0));
      expect(last.maxCorrelation, greaterThan(0.0));
      expect(channel.latest, isNotNull);

      await sub.cancel();
      await host.dispose();
    });
  });
}
