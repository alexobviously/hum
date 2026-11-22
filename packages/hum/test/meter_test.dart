import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:test/test.dart';

void main() {
  group('Meter', () {
    test('passes audio through unchanged and measures peak and RMS', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(
        context: context,
        telemetryInterval: const Duration(milliseconds: 10),
      );

      // 440 Hz sine wave with peak 0.5 -> RMS = 0.5 / sqrt(2) ~= 0.3536.
      final osc = SineOscillator(frequency: const .value(440.0));
      final scaled = Mult.mono(input: osc.outlet, value: const .value(0.5));
      final meter = Meter.mono(input: scaled.outlet);
      final out = Out.mono(meter.outlet);

      expect(host.setGraph(root: out), isEmpty);

      final channel = host.telemetryOf(meter)!;
      final readings = <MeterReading>[];
      final sub = channel.stream.listen(readings.add);

      final rendered = await host.renderBlocks(40);
      await Future<void>.delayed(Duration.zero);

      // Verify passthrough audio is non-silent and bounded by 0.5.
      double maxOut = 0.0;
      for (final block in rendered) {
        for (final s in block) {
          if (s.abs() > maxOut) maxOut = s.abs();
        }
      }
      expect(maxOut, closeTo(0.5, 0.01));

      expect(readings, isNotEmpty);
      final last = readings.last;
      expect(last.channels, hasLength(1));
      expect(last.peak, closeTo(0.5, 0.01));
      expect(last.rms, closeTo(0.5 / math.sqrt2, 0.02));
      expect(last.peakDb, closeTo(gainToDb(0.5), 0.2));
      expect(last.clipped, isFalse);

      await sub.cancel();
      await host.dispose();
    });

    test('measures independent stereo channels and detects clipping', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(
        context: context,
        telemetryInterval: const Duration(milliseconds: 10),
      );

      final osc = SineOscillator(frequency: const .value(500.0));
      final left = Mult.mono(input: osc.outlet, value: const .value(0.25));
      final right = Mult.mono(input: osc.outlet, value: const .value(1.2));
      final meter = Meter.stereo(left: left.outlet, right: right.outlet);
      final out = Out.stereo(left: meter.left, right: meter.right);

      expect(host.setGraph(root: out), isEmpty);

      final channel = host.telemetryOf(meter)!;
      await host.renderBlocks(40);

      final reading = channel.latest;
      expect(reading, isNotNull);
      expect(reading!.channels, hasLength(2));
      expect(reading.left.peak, closeTo(0.25, 0.01));
      expect(reading.left.clipped, isFalse);
      expect(reading.right.peak, closeTo(1.2, 0.02));
      expect(reading.right.clipped, isTrue);
      expect(reading.clipped, isTrue);
      expect(reading.peak, closeTo(1.2, 0.02));

      await host.dispose();
    });

    test('captures 1-sample transient peaks and resets between flushes', () {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final proc = MeterProcessor(numChannels: 1);
      final inp = Float32List(64);
      final out = Float32List(64);
      final telemetry = Float32List(2);

      // Nothing processed yet -> writeTelemetry returns false.
      expect(proc.writeTelemetry(telemetry, 0), isFalse);

      // Single -0.8 spike at sample 17.
      inp[17] = -0.8;
      proc.process(context, [inp], [out]);
      expect(out[17], closeTo(-0.8, 1e-6));

      // Follow with a silent block before flushing -> peak is still preserved.
      inp[17] = 0.0;
      proc.process(context, [inp], [out]);

      expect(proc.writeTelemetry(telemetry, 0), isTrue);
      expect(telemetry[0], closeTo(0.8, 1e-6));
      expect(telemetry[1], closeTo(math.sqrt(0.64 / 128.0), 1e-5));

      // Flush resets accumulators; next silent block reports 0.0.
      proc.process(context, [inp], [out]);
      expect(proc.writeTelemetry(telemetry, 0), isTrue);
      expect(telemetry[0], equals(0.0));
      expect(telemetry[1], equals(0.0));
    });

    test('works as a side-tap root via setGraph(roots: [out, meter])', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(
        context: context,
        telemetryInterval: const Duration(milliseconds: 10),
      );

      final osc = SineOscillator(frequency: const .value(440.0));
      final out = Out.mono(osc.outlet);
      final tap = Meter.mono(input: osc.outlet);

      expect(host.setGraph(roots: [out, tap]), isEmpty);
      final channel = host.telemetryOf(tap)!;

      await host.renderBlocks(40);
      expect(channel.latest, isNotNull);
      expect(channel.latest!.peak, closeTo(1.0, 0.02));

      // Unplug the side-tap without rewiring `osc -> out`.
      expect(host.setGraph(root: out), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(channel.isClosed, isTrue);

      await host.dispose();
    });

    test('streams MeterReading across IsolateAudioHost', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = await IsolateAudioHost.spawn(
        context: context,
        telemetryInterval: const Duration(milliseconds: 10),
      );
      try {
        final osc = SineOscillator(frequency: const .value(440.0));
        final meter = osc.outlet.meter();
        expect(host.setGraph(root: Out.mono(meter.outlet)), isEmpty);

        final channel = host.telemetryOf(meter)!;
        final readingFuture = channel.stream.first.timeout(
          const Duration(seconds: 2),
        );

        await host.renderBlocks(40);
        final reading = await readingFuture;
        expect(reading.peak, closeTo(1.0, 0.02));
      } finally {
        await host.dispose();
      }
    });
  });
}
