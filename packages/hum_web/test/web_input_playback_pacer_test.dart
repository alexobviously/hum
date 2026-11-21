import 'dart:async';
import 'dart:typed_data';

import 'package:hum_web/src/input_ring_buffer.dart';
import 'package:hum_web/src/web_input_playback_pacer.dart';
import 'package:test/test.dart';

void main() {
  group('InputRingBuffer', () {
    test('pushes and pops interleaved frames across wrap-around', () {
      final ring = InputRingBuffer(numChannels: 2, capacityFrames: 4);

      ring.pushInterleaved(
        Float32List.fromList([1, 10, 2, 20, 3, 30]),
        3,
      );
      expect(ring.availableFrames, equals(3));

      final out = Float32List(4);
      ring.popInterleaved(out, 2);
      expect(out, equals([1, 10, 2, 20]));
      expect(ring.availableFrames, equals(1));

      // Push 3 more frames to wrap around capacity 4
      ring.pushInterleaved(
        Float32List.fromList([4, 40, 5, 50, 6, 60]),
        3,
      );
      expect(ring.availableFrames, equals(4));
      expect(ring.overruns, equals(0));

      final outAll = Float32List(8);
      ring.popInterleaved(outAll, 4);
      expect(outAll, equals([3, 30, 4, 40, 5, 50, 6, 60]));
      expect(ring.availableFrames, equals(0));
    });

    test('drops oldest frames and counts overruns when full', () {
      final ring = InputRingBuffer(numChannels: 1, capacityFrames: 4);
      ring.pushInterleaved(Float32List.fromList([1, 2, 3]), 3);
      ring.pushInterleaved(Float32List.fromList([4, 5, 6]), 3);

      expect(ring.overruns, equals(1));
      expect(ring.availableFrames, equals(4));

      final out = Float32List(4);
      ring.popInterleaved(out, 4);
      expect(out, equals([3, 4, 5, 6]));
    });

    test('zero-fills shortfall and counts underruns', () {
      final ring = InputRingBuffer(numChannels: 1, capacityFrames: 4);
      ring.pushInterleaved(Float32List.fromList([7, 8]), 2);

      final out = Float32List.fromList([99, 99, 99, 99]);
      ring.popInterleaved(out, 4);
      expect(out, equals([7, 8, 0, 0]));
      expect(ring.underruns, equals(1));
      expect(ring.availableFrames, equals(0));
    });
  });

  group('WebInputPlaybackPacer', () {
    test('returns synchronous null when enough frames are buffered', () {
      int available = 256;
      final pacer = WebInputPlaybackPacer(
        vectorSize: 128,
        availableReadFrames: () => available,
        isStopped: () => false,
      );
      pacer.start();

      expect(pacer.waitForNextBlock(), isNull);
      available = 128;
      expect(pacer.waitForNextBlock(), isNull);
    });

    test(
      'suspends when empty and wakes immediately on onFramesAvailable',
      () async {
        int available = 0;
        final pacer = WebInputPlaybackPacer(
          vectorSize: 128,
          availableReadFrames: () => available,
          isStopped: () => false,
        );
        pacer.start();

        final wait = pacer.waitForNextBlock();
        expect(wait, isA<Future<void>>());

        bool woken = false;
        final done = (wait as Future<void>).then((_) {
          woken = true;
        });

        available = 64;
        pacer.onFramesAvailable();
        await Future<void>.delayed(Duration.zero);
        expect(woken, isFalse);

        available = 128;
        pacer.onFramesAvailable();
        await done;
        expect(woken, isTrue);
      },
    );

    test('stop immediately wakes a pending waitForNextBlock', () async {
      final pacer = WebInputPlaybackPacer(
        vectorSize: 128,
        availableReadFrames: () => 0,
        isStopped: () => false,
      );
      pacer.start();

      final wait = pacer.waitForNextBlock();
      expect(wait, isA<Future<void>>());

      pacer.stop();
      await (wait as Future<void>).timeout(const Duration(milliseconds: 200));
      expect(pacer.waitForNextBlock(), isNull);
    });
  });
}
