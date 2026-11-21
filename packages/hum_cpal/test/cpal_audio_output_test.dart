import 'dart:async';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_cpal/hum_cpal.dart';
import 'package:test/test.dart';

void main() {
  group('CpalPlaybackPacer', () {
    test('returns synchronous null when ring buffer has enough space', () {
      final pacer = CpalPlaybackPacer(
        sampleRate: 48000,
        vectorSize: 64,
        availableFrames: () => 128,
        isStopped: () => false,
      )..start();

      expect(pacer.waitForNextBlock(), isNull);
      pacer.stop();
    });

    test('waits asynchronously until enough frames drain', () async {
      int available = 16;
      final pacer = CpalPlaybackPacer(
        sampleRate: 48000,
        vectorSize: 64,
        availableFrames: () => available,
        isStopped: () => false,
      )..start();

      final wait = pacer.waitForNextBlock();
      expect(wait, isA<Future<void>>());

      bool resolved = false;
      final future = (wait as Future<void>).then((_) => resolved = true);

      // Still below vectorSize on early check -> remains pending.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(resolved, isFalse);

      // Simulate hardware callback freeing space.
      available = 256;
      await future.timeout(const Duration(milliseconds: 100));
      expect(resolved, isTrue);

      pacer.stop();
    });

    test('completes pending wait immediately when stop() is called', () async {
      final pacer = CpalPlaybackPacer(
        sampleRate: 48000,
        vectorSize: 64,
        availableFrames: () => 0,
        isStopped: () => false,
      )..start();

      final wait = pacer.waitForNextBlock();
      expect(wait, isA<Future<void>>());

      bool resolved = false;
      final future = (wait as Future<void>).then((_) => resolved = true);

      pacer.stop();
      await future.timeout(const Duration(milliseconds: 50));
      expect(resolved, isTrue);
    });

    test('wakes up promptly if stream stops unexpectedly', () async {
      bool stopped = false;
      final pacer = CpalPlaybackPacer(
        sampleRate: 48000,
        vectorSize: 64,
        availableFrames: () => 0,
        isStopped: () => stopped,
      )..start();

      final wait = pacer.waitForNextBlock();
      expect(wait, isA<Future<void>>());

      Timer(const Duration(milliseconds: 2), () => stopped = true);
      await (wait as Future<void>).timeout(const Duration(milliseconds: 100));
      pacer.stop();
    });
  });

  group('CpalAudioOutput & CpalAudioOutputDriver', () {
    test(
      'descriptor is isolate-sendable and validates preconditions',
      () async {
        const output = CpalAudioOutput(
          numChannels: 2,
          vectorSize: 64,
          deviceId: 'nonexistent-device',
          bufferFrames: 1024,
        );
        expect(output.isIsolateSendable, isTrue);

        final driver = output.createDriver() as CpalAudioOutputDriver;
        const context = ProcessContext(sampleRate: 48000, vectorSize: 64);

        expect(() => driver.createPacer(context), throwsStateError);
        expect(
          () => driver.start(
            const ProcessContext(sampleRate: 48000, vectorSize: 128),
          ),
          throwsArgumentError,
        );
        expect(() => driver.start(context), throwsStateError);

        await driver.close();
        await driver.close();
        expect(driver.isClosed, isTrue);
        expect(driver.isOpen, isFalse);
      },
    );

    test('rejects bufferFrames smaller than vectorSize on start', () async {
      final driver = CpalAudioOutputDriver(
        numChannels: 2,
        vectorSize: 128,
        bufferFrames: 64,
      );
      expect(
        () => driver.start(
          const ProcessContext(sampleRate: 48000, vectorSize: 128),
        ),
        throwsArgumentError,
      );
      await driver.close();
    });

    test(
      'supports fixed hardwareBufferFrames and rejects non-positive',
      () async {
        final invalidDriver = CpalAudioOutputDriver(
          numChannels: 2,
          vectorSize: 64,
          bufferFrames: 256,
          hardwareBufferFrames: 0,
        );
        expect(
          () => invalidDriver.start(
            const ProcessContext(sampleRate: 48000, vectorSize: 64),
          ),
          throwsArgumentError,
        );
        await invalidDriver.close();

        final snapshot = CpalHostSnapshot.probe();
        final defaultOut = snapshot.defaultOutputDevice;
        final cfg = defaultOut?.defaultOutput;
        final range = cfg?.bufferSize;
        if (defaultOut == null ||
            cfg == null ||
            cfg.sampleFormat != CpalSampleFormat.f32 ||
            range == null) {
          return;
        }

        final target = 64.clamp(range.min, range.max);
        final driver = CpalAudioOutputDriver(
          numChannels: cfg.channels,
          vectorSize: 64,
          bufferFrames: 256,
          hardwareBufferFrames: target,
        );
        try {
          driver.start(
            ProcessContext(sampleRate: cfg.sampleRate, vectorSize: 64),
          );
          expect(driver.isOpen, isTrue);
          expect(driver.isStopped, isFalse);
        } finally {
          await driver.close();
        }
      },
    );

    test(
      'streams silent audio through IsolateAudioHost on default f32 device',
      () async {
        final snapshot = CpalHostSnapshot.probe();
        final defaultOut = snapshot.devices.cast<CpalDeviceInfo?>().firstWhere(
          (d) =>
              d != null &&
              d.isDefaultOutput &&
              d.defaultOutput?.sampleFormat == CpalSampleFormat.f32,
          orElse: () => null,
        );
        if (defaultOut == null) return;

        final cfg = defaultOut.defaultOutput!;
        const vectorSize = 64;
        final context = ProcessContext(
          sampleRate: cfg.sampleRate,
          vectorSize: vectorSize,
        );

        final host = await IsolateAudioHost.spawn(context: context);
        final errors = <AudioPlaybackError>[];
        final errorSub = host.playbackErrors.listen(errors.add);
        try {
          final osc = SineOscillator(frequency: const .value(440));
          final silent = Mult.mono(value: const .value(0.0), input: osc.outlet);
          final diagnostics = host.setGraph(
            targetOutputs: [
              for (int c = 0; c < cfg.channels; c++) silent.outlet,
            ],
          );
          expect(diagnostics, isEmpty);

          final output = CpalAudioOutput(
            numChannels: cfg.channels,
            vectorSize: vectorSize,
            bufferFrames: 2048,
          );
          await host.startPlayback(output: output);
          await Future<void>.delayed(const Duration(milliseconds: 35));
          await host.stopPlayback();

          expect(errors, isEmpty);
        } finally {
          await errorSub.cancel();
          await host.dispose();
        }
      },
    );

    test(
      'SyncAudioHost starts, writes blocks, and closes cleanly on f32 device',
      () async {
        final snapshot = CpalHostSnapshot.probe();
        final defaultOut = snapshot.devices.cast<CpalDeviceInfo?>().firstWhere(
          (d) =>
              d != null &&
              d.isDefaultOutput &&
              d.defaultOutput?.sampleFormat == CpalSampleFormat.f32,
          orElse: () => null,
        );
        if (defaultOut == null) return;

        final cfg = defaultOut.defaultOutput!;
        const vectorSize = 64;
        final driver = CpalAudioOutputDriver(
          numChannels: cfg.channels,
          vectorSize: vectorSize,
          bufferFrames: 2048,
        );
        final context = ProcessContext(
          sampleRate: cfg.sampleRate,
          vectorSize: vectorSize,
        );
        try {
          driver.start(context);
          expect(driver.isOpen, isTrue);
          expect(driver.isStopped, isFalse);

          final pacer = driver.createPacer(context)..start();
          final silentChannels = [
            for (int c = 0; c < cfg.channels; c++) Float32List(vectorSize),
          ];
          for (int i = 0; i < 4; i++) {
            final wait = pacer.waitForNextBlock();
            if (wait is Future<void>) await wait;
            driver.write(silentChannels);
            pacer.onBlockProcessed();
          }
          expect(driver.underruns, greaterThanOrEqualTo(0));
          pacer.stop();
        } finally {
          await driver.close();
          expect(driver.isOpen, isFalse);
          expect(driver.isClosed, isTrue);
        }
      },
    );
  });
}
