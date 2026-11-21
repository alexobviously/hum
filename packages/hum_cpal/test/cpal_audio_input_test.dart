import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_cpal/hum_cpal.dart';
import 'package:test/test.dart';

void main() {
  group('CpalAudioInput & CpalAudioInputDriver', () {
    test(
      'descriptor is isolate-sendable and validates preconditions',
      () async {
        const input = CpalAudioInput(
          numChannels: 1,
          vectorSize: 64,
          deviceId: 'nonexistent-device',
          bufferFrames: 1024,
        );
        expect(input.isIsolateSendable, isTrue);

        final driver = input.createDriver() as CpalAudioInputDriver;
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
      final driver = CpalAudioInputDriver(
        numChannels: 1,
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

    test('supports fixed hardwareBufferFrames and rejects non-positive', () async {
      final invalidDriver = CpalAudioInputDriver(
        numChannels: 1,
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
      final defaultIn = snapshot.defaultInputDevice;
      final cfg = defaultIn?.defaultInput;
      final range = cfg?.bufferSize;
      if (defaultIn == null || cfg == null || range == null) {
        return;
      }

      final target = 64.clamp(range.min, range.max);
      final driver = CpalAudioInputDriver(
        numChannels: cfg.channels,
        vectorSize: 64,
        bufferFrames: 256,
        hardwareBufferFrames: target,
      );
      try {
        driver.start(ProcessContext(sampleRate: cfg.sampleRate, vectorSize: 64));
        expect(driver.isOpen, isTrue);
        expect(driver.isStopped, isFalse);
      } finally {
        await driver.close();
      }
    });

    test(
      'read() zero-fills channels when driver is not started or closed',
      () async {
        final driver = CpalAudioInputDriver(
          numChannels: 2,
          vectorSize: 4,
          bufferFrames: 16,
        );
        final channels = [
          Float32List.fromList([1, 2, 3, 4]),
          Float32List.fromList([5, 6, 7, 8]),
        ];
        driver.read(channels);
        expect(channels[0], everyElement(0.0));
        expect(channels[1], everyElement(0.0));
        await driver.close();
      },
    );

    test(
      'captures input-only audio through IsolateAudioHost on default input',
      () async {
        final snapshot = CpalHostSnapshot.probe();
        final defaultIn = snapshot.defaultInputDevice;
        final cfg = defaultIn?.defaultInput;
        if (defaultIn == null || cfg == null) return;

        const vectorSize = 64;
        final context = ProcessContext(
          sampleRate: cfg.sampleRate,
          vectorSize: vectorSize,
        );

        final host = await IsolateAudioHost.spawn(context: context);
        final errors = <AudioPlaybackError>[];
        final errorSub = host.playbackErrors.listen(errors.add);
        try {
          final mic = In(
            channels: [for (int c = 0; c < cfg.channels; c++) c],
          );
          final diagnostics = host.setGraph(targetOutputs: mic.outlets);
          expect(diagnostics, isEmpty);

          final input = CpalAudioInput(
            numChannels: cfg.channels,
            vectorSize: vectorSize,
            bufferFrames: 2048,
          );
          await host.startPlayback(input: input);
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
      'CpalAudioInputDriver starts, reads blocks, and closes cleanly',
      () async {
        final snapshot = CpalHostSnapshot.probe();
        final defaultIn = snapshot.defaultInputDevice;
        final cfg = defaultIn?.defaultInput;
        if (defaultIn == null || cfg == null) return;

        const vectorSize = 64;
        final driver = CpalAudioInputDriver(
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
          final channels = [
            for (int c = 0; c < cfg.channels; c++) Float32List(vectorSize),
          ];
          for (int i = 0; i < 4; i++) {
            final wait = pacer.waitForNextBlock();
            if (wait is Future<void>) {
              await wait.timeout(const Duration(seconds: 2));
            }
            driver.read(channels);
            pacer.onBlockProcessed();
          }
          expect(driver.overruns, greaterThanOrEqualTo(0));
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
