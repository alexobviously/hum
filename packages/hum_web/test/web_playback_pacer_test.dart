import 'dart:async';

import 'package:hum_web/src/web_playback_pacer.dart';
import 'package:test/test.dart';

void main() {
  group('WebPlaybackPacer', () {
    test(
      'returns synchronous null while buffer has capacity for another block',
      () {
        final pacer = WebPlaybackPacer(
          vectorSize: 128,
          bufferFrames: 384,
          isStopped: () => false,
        );
        pacer.start();

        // 3 blocks of 128 fit into 384 frames synchronously
        for (int i = 0; i < 3; i++) {
          final wait = pacer.waitForNextBlock();
          expect(wait, isNull);
          pacer.onBlockProcessed();
        }

        expect(pacer.queuedFrames, equals(384));
        expect(pacer.availableWriteFrames, equals(0));
      },
    );

    test(
      'suspends when full and wakes immediately when onFramesConsumed frees a block',
      () async {
        final pacer = WebPlaybackPacer(
          vectorSize: 128,
          bufferFrames: 256,
          isStopped: () => false,
        );
        pacer.start();

        // Fill buffer (2 blocks)
        expect(pacer.waitForNextBlock(), isNull);
        pacer.onBlockProcessed();
        expect(pacer.waitForNextBlock(), isNull);
        pacer.onBlockProcessed();

        // 3rd block must wait
        final wait = pacer.waitForNextBlock();
        expect(wait, isA<Future<void>>());

        bool woken = false;
        final future = (wait as Future<void>).then((_) {
          woken = true;
        });

        // Partial drain (< 128) is not enough for a full block yet
        pacer.onFramesConsumed(64);
        await Future<void>.delayed(Duration.zero);
        expect(woken, isFalse);

        // Next 64 frees a full 128-frame block -> wakes immediately
        pacer.onFramesConsumed(64);
        await future;
        expect(woken, isTrue);
        expect(pacer.queuedFrames, equals(128));
      },
    );

    test('stop immediately wakes a pending waitForNextBlock', () async {
      final pacer = WebPlaybackPacer(
        vectorSize: 128,
        bufferFrames: 128,
        isStopped: () => false,
      );
      pacer.start();

      expect(pacer.waitForNextBlock(), isNull);
      pacer.onBlockProcessed();

      final wait = pacer.waitForNextBlock();
      expect(wait, isA<Future<void>>());

      pacer.stop();
      await (wait as Future<void>).timeout(const Duration(milliseconds: 200));

      // Subsequent calls while stopped return synchronous null
      expect(pacer.waitForNextBlock(), isNull);
    });

    test('returns synchronous null when isStopped reports true', () {
      bool stopped = false;
      final pacer = WebPlaybackPacer(
        vectorSize: 128,
        bufferFrames: 128,
        isStopped: () => stopped,
      );
      pacer.start();
      pacer.onBlockProcessed();

      stopped = true;
      expect(pacer.waitForNextBlock(), isNull);
    });

    test('clamps queuedFrames at zero on excess consumption reports', () {
      final pacer = WebPlaybackPacer(
        vectorSize: 128,
        bufferFrames: 256,
        isStopped: () => false,
      );
      pacer.start();
      pacer.onBlockProcessed();

      pacer.onFramesConsumed(512);
      expect(pacer.queuedFrames, equals(0));
      expect(pacer.availableWriteFrames, equals(256));
    });
  });
}
