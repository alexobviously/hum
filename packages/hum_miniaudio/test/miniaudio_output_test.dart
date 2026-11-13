import 'dart:async';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_miniaudio/hum_miniaudio.dart';
import 'package:test/test.dart';

void main() {
  group('MiniaudioOutput', () {
    test('reports configuration and isolate sendability', () {
      const output = MiniaudioOutput(
        numChannels: 2,
        vectorSize: 256,
        bufferFrames: 1024,
      );

      expect(output.numChannels, 2);
      expect(output.vectorSize, 256);
      expect(output.bufferFrames, 1024);
      expect(output.isIsolateSendable, isTrue);

      final driver = output.createDriver();
      expect(driver, isA<MiniaudioOutputDriver>());
      expect(driver.numChannels, 2);
      expect(driver.vectorSize, 256);
    });

    test('validates positive configuration invariants', () {
      expect(
        () => MiniaudioOutput(numChannels: 0, vectorSize: 256),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MiniaudioOutput(numChannels: 2, vectorSize: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () =>
            MiniaudioOutput(numChannels: 2, vectorSize: 512, bufferFrames: 256),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('miniaudio native asset', () {
    test('loads native library and reports version', () {
      expect(miniaudioVersion, '0.11.26');
    });

    test('driver enforces lifecycle and context validation', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 256);
      final driver = MiniaudioOutputDriver(numChannels: 2, vectorSize: 512);

      expect(() => driver.start(context), throwsArgumentError);

      await driver.close();
      await driver.close();
      expect(() => driver.start(context), throwsStateError);
    });

    test('streams silent audio cleanly via SyncAudioHost', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 512);
      final host = AudioHost.sync(context: context);
      final errors = <AudioPlaybackError>[];
      final sub = host.playbackErrors.listen(errors.add);

      try {
        final silent = const SineOscillator(frequency: .value(0));
        host.setGraph(
          root: Out.stereo(left: silent.outlet, right: silent.outlet),
        );

        await host.startPlayback(
          const MiniaudioOutput(numChannels: 2, vectorSize: 512),
        );
        expect(host.isPlaying, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 60));
        await host.stopPlayback();

        expect(host.isPlaying, isFalse);
        expect(errors, isEmpty);
      } finally {
        await sub.cancel();
        await host.dispose();
      }
    });

    test('streams silent audio cleanly via IsolateAudioHost', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 512);
      final host = await IsolateAudioHost.spawn(context: context);
      final errors = <AudioPlaybackError>[];
      final sub = host.playbackErrors.listen(errors.add);

      try {
        final silent = const SineOscillator(frequency: .value(0));
        host.setGraph(
          root: Out.stereo(left: silent.outlet, right: silent.outlet),
        );

        await host.startPlayback(
          const MiniaudioOutput(numChannels: 2, vectorSize: 512),
        );
        expect(host.isPlaying, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 60));
        await host.stopPlayback();

        expect(host.isPlaying, isFalse);
        expect(errors, isEmpty);
      } finally {
        await sub.cancel();
        await host.dispose();
      }
    });

    test('pacer takes sync fast-path and cancels cleanly on stop', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 512);
      final driver = MiniaudioOutputDriver(
        numChannels: 2,
        vectorSize: 512,
        bufferFrames: 1024,
      );
      driver.start(context);

      try {
        final pacer = driver.createPacer(context)..start();
        final silent = [Float32List(512), Float32List(512)];

        // With 1024 capacity, first wait returns synchronously.
        final firstWait = pacer.waitForNextBlock();
        expect(firstWait, isNull);
        driver.write(silent);

        // Fill until ring buffer drops below vectorSize, then verify stop()
        // unblocks waitForNextBlock() immediately.
        var writes = 1;
        while (driver.availableWriteFrames >= driver.vectorSize && writes < 8) {
          expect(pacer.waitForNextBlock(), isNull);
          driver.write(silent);
          writes++;
        }

        final pending = pacer.waitForNextBlock();
        if (pending is Future<void>) {
          pacer.stop();
          await pending.timeout(const Duration(milliseconds: 50));
        } else {
          pacer.stop();
        }
      } finally {
        await driver.close();
      }
    });
  });
}
