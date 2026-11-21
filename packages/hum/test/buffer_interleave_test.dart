import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Buffer Interleaving', () {
    test('interleaveFloats mono copies directly', () {
      final ch0 = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
      final target = Float32List(4);

      interleaveFloats([ch0], target);

      expect(target, equals([1.0, 2.0, 3.0, 4.0]));
    });

    test('interleaveFloats stereo alternates left and right channels', () {
      final left = Float32List.fromList([1.0, 3.0, 5.0]);
      final right = Float32List.fromList([2.0, 4.0, 6.0]);
      final target = Float32List(6);

      interleaveFloats([left, right], target);

      expect(target, equals([1.0, 2.0, 3.0, 4.0, 5.0, 6.0]));
    });

    test('interleaveFloats N channels (quad) interleaves correctly', () {
      final ch0 = Float32List.fromList([1.0, 5.0]);
      final ch1 = Float32List.fromList([2.0, 6.0]);
      final ch2 = Float32List.fromList([3.0, 7.0]);
      final ch3 = Float32List.fromList([4.0, 8.0]);
      final target = Float32List(8);

      interleaveFloats([ch0, ch1, ch2, ch3], target);

      expect(target, equals([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]));
    });

    test('interleavePcm16 scales and clamps float values', () {
      // 0.0 -> 0, 1.0 -> 32767, -1.0 -> -32767, clamped > 1.0, clamped < -1.0
      final ch0 = Float32List.fromList([0.0, 1.0, -1.0, 2.5, -3.0, 0.5]);
      final target = Int16List(6);

      interleavePcm16([ch0], target);

      expect(target[0], equals(0));
      expect(target[1], equals(32767));
      expect(target[2], equals(-32767));
      expect(target[3], equals(32767)); // clamped
      expect(target[4], equals(-32767)); // clamped
      expect(target[5], equals(16384)); // 0.5 * 32767 = 16383.5 -> 16384
    });

    test('interleavePcm16 stereo interleaves and converts', () {
      final left = Float32List.fromList([0.0, 1.0]);
      final right = Float32List.fromList([-1.0, 0.5]);
      final target = Int16List(4);

      interleavePcm16([left, right], target);

      expect(target, equals([0, -32767, 32767, 16384]));
    });

    test('deinterleaveFloats round-trips with interleaveFloats', () {
      final originalLeft = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);
      final originalRight = Float32List.fromList([0.5, 0.6, 0.7, 0.8]);
      final interleaved = Float32List(8);

      interleaveFloats([originalLeft, originalRight], interleaved);

      final recoveredLeft = Float32List(4);
      final recoveredRight = Float32List(4);
      deinterleaveFloats(interleaved, [recoveredLeft, recoveredRight]);

      expect(recoveredLeft, equals(originalLeft));
      expect(recoveredRight, equals(originalRight));
    });

    test('deinterleavePcm16 mono and stereo converts to normalized floats', () {
      final pcmMono = Int16List.fromList([0, 16384, -16384, 32767, -32768]);
      final outMono = Float32List(5);
      deinterleavePcm16(pcmMono, [outMono]);

      expect(outMono[0], closeTo(0.0, 1e-4));
      expect(outMono[1], closeTo(0.5, 1e-4));
      expect(outMono[2], closeTo(-0.5, 1e-4));
      expect(outMono[3], closeTo(0.999969, 1e-4));
      expect(outMono[4], closeTo(-1.0, 1e-4));

      final pcmStereo = Int16List.fromList([0, 16384, -16384, 32767]);
      final outLeft = Float32List(2);
      final outRight = Float32List(2);
      deinterleavePcm16(pcmStereo, [outLeft, outRight]);

      expect(outLeft[0], closeTo(0.0, 1e-4));
      expect(outRight[0], closeTo(0.5, 1e-4));
      expect(outLeft[1], closeTo(-0.5, 1e-4));
      expect(outRight[1], closeTo(0.999969, 1e-4));
    });

    test(
      'BufferInterleaver lazily allocates and produces correct byte views',
      () {
        final interleaver = BufferInterleaver(numChannels: 2, vectorSize: 4);

        expect(interleaver.totalSamples, equals(8));

        final left = Float32List.fromList([1.0, 3.0, 5.0, 7.0]);
        final right = Float32List.fromList([2.0, 4.0, 6.0, 8.0]);

        // Float32 byte view: 8 samples * 4 bytes = 32 bytes
        final floatBytes = interleaver.interleaveFloat32Bytes([left, right]);
        expect(floatBytes.length, equals(32));

        final floatView = floatBytes.buffer.asFloat32List(
          floatBytes.offsetInBytes,
          8,
        );
        expect(floatView, equals([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]));

        // PCM16 byte view: 8 samples * 2 bytes = 16 bytes
        final pcmBytes = interleaver.interleavePcm16Bytes([left, right]);
        expect(pcmBytes.length, equals(16));

        final pcmView = pcmBytes.buffer.asInt16List(
          pcmBytes.offsetInBytes,
          8,
        );
        // All values >= 1.0 clamp to 32767
        expect(
          pcmView,
          equals([32767, 32767, 32767, 32767, 32767, 32767, 32767, 32767]),
        );
      },
    );

    test('interleaveFloats handles SIMD blocks with scalar tails and 3/4/5 channels', () {
      // Stereo length 11 (2 SIMD chunks of 4 + 3 scalar tail)
      final left = Float32List.fromList([
        for (int i = 0; i < 11; i++) i.toDouble(),
      ]);
      final right = Float32List.fromList([
        for (int i = 0; i < 11; i++) (i + 100).toDouble(),
      ]);
      final stereoOut = Float32List(22);
      interleaveFloats([left, right], stereoOut);
      for (int i = 0; i < 11; i++) {
        expect(stereoOut[i * 2], equals(left[i]));
        expect(stereoOut[i * 2 + 1], equals(right[i]));
      }

      // Quad length 10 (2 SIMD chunks of 4 + 2 scalar tail)
      final q0 = Float32List.fromList([for (int i = 0; i < 10; i++) i + 0.0]);
      final q1 = Float32List.fromList([for (int i = 0; i < 10; i++) i + 10.0]);
      final q2 = Float32List.fromList([for (int i = 0; i < 10; i++) i + 20.0]);
      final q3 = Float32List.fromList([for (int i = 0; i < 10; i++) i + 30.0]);
      final quadOut = Float32List(40);
      interleaveFloats([q0, q1, q2, q3], quadOut);
      for (int i = 0; i < 10; i++) {
        expect(quadOut[i * 4 + 0], equals(q0[i]));
        expect(quadOut[i * 4 + 1], equals(q1[i]));
        expect(quadOut[i * 4 + 2], equals(q2[i]));
        expect(quadOut[i * 4 + 3], equals(q3[i]));
      }

      // Round-trip deinterleaveFloats for quad length 10
      final r0 = Float32List(10);
      final r1 = Float32List(10);
      final r2 = Float32List(10);
      final r3 = Float32List(10);
      deinterleaveFloats(quadOut, [r0, r1, r2, r3]);
      expect(r0, equals(q0));
      expect(r1, equals(q1));
      expect(r2, equals(q2));
      expect(r3, equals(q3));
    });

    test(
      'interleave/deinterleave handle unaligned Float32List subviews safely',
      () {
        final backingA = Float32List.fromList([99, 1, 2, 3, 4, 5, 6, 7, 8]);
        final backingB = Float32List.fromList([
          99,
          11,
          12,
          13,
          14,
          15,
          16,
          17,
          18,
        ]);
        final subA = Float32List.sublistView(backingA, 1); // offsetInBytes = 4
        final subB = Float32List.sublistView(backingB, 1);
        final backingOut = Float32List(17);
        final subOut = Float32List.sublistView(backingOut, 1);

        interleaveFloats([subA, subB], subOut);
        expect(
          subOut,
          equals([1, 11, 2, 12, 3, 13, 4, 14, 5, 15, 6, 16, 7, 17, 8, 18]),
        );

        final recA = Float32List.sublistView(Float32List(9), 1);
        final recB = Float32List.sublistView(Float32List(9), 1);
        deinterleaveFloats(subOut, [recA, recB]);
        expect(recA, equals(subA));
        expect(recB, equals(subB));

        final pcmInBacking = Float32List.fromList([
          0.0,
          -1.0,
          0.0,
          1.0,
          0.5,
          -0.5,
          2.0,
          -2.0,
          0.25,
        ]);
        final subPcmIn = Float32List.sublistView(pcmInBacking, 1);
        final pcmOut = Int16List(8);
        interleavePcm16([subPcmIn], pcmOut);
        expect(
          pcmOut,
          equals([-32767, 0, 32767, 16384, -16384, 32767, -32767, 8192]),
        );
      },
    );

    test(
      'interleavePcm16 handles SIMD mono, stereo, and multi-channel with tails',
      () {
        // Mono length 9 (2 SIMD chunks + 1 tail)
        final mono = Float32List.fromList([
          0.0,
          1.0,
          -1.0,
          0.5,
          -0.5,
          2.0,
          -2.0,
          0.25,
          -0.25,
        ]);
        final monoOut = Int16List(9);
        interleavePcm16([mono], monoOut);
        expect(
          monoOut,
          equals([0, 32767, -32767, 16384, -16384, 32767, -32767, 8192, -8192]),
        );

        // Stereo length 6 (1 SIMD chunk + 2 tail)
        final left = Float32List.fromList([0.0, 1.0, -1.0, 0.5, -0.5, 2.0]);
        final right = Float32List.fromList([-1.0, 0.5, 0.0, -0.5, 1.0, -2.0]);
        final stereoOut = Int16List(12);
        interleavePcm16([left, right], stereoOut);
        expect(
          stereoOut,
          equals([
            0,
            -32767,
            32767,
            16384,
            -32767,
            0,
            16384,
            -16384,
            -16384,
            32767,
            32767,
            -32767,
          ]),
        );

        // 3-channel length 5 (1 SIMD chunk + 1 tail)
        final c0 = Float32List.fromList([0.0, 1.0, -1.0, 0.5, -0.5]);
        final c1 = Float32List.fromList([1.0, -1.0, 0.5, -0.5, 0.0]);
        final c2 = Float32List.fromList([-1.0, 0.5, -0.5, 0.0, 1.0]);
        final triOut = Int16List(15);
        interleavePcm16([c0, c1, c2], triOut);
        expect(
          triOut,
          equals([
            0,
            32767,
            -32767,
            32767,
            -32767,
            16384,
            -32767,
            16384,
            -16384,
            16384,
            -16384,
            0,
            -16384,
            0,
            32767,
          ]),
        );
      },
    );

    test(
      'BufferInterleaver caches views and handles buffer swaps and tails',
      () {
        final interleaver = BufferInterleaver(numChannels: 2, vectorSize: 6);
        final left1 = Float32List.fromList([0.0, 0.25, 0.5, 0.75, 1.0, -1.0]);
        final right1 = Float32List.fromList([-1.0, 1.0, -0.5, 0.5, 0.0, 0.25]);
        final target = Float32List(12);

        interleaver.interleaveFloatsTo([left1, right1], target);
        expect(
          target,
          equals([
            0.0,
            -1.0,
            0.25,
            1.0,
            0.5,
            -0.5,
            0.75,
            0.5,
            1.0,
            0.0,
            -1.0,
            0.25,
          ]),
        );

        // Swap channel buffers on subsequent block to verify cache updates
        final left2 = Float32List.fromList([1.0, 1.0, 1.0, 1.0, 1.0, 1.0]);
        final right2 = Float32List.fromList([
          -1.0,
          -1.0,
          -1.0,
          -1.0,
          -1.0,
          -1.0,
        ]);
        interleaver.interleaveFloatsTo([left2, right2], target);
        expect(
          target,
          equals([
            1.0,
            -1.0,
            1.0,
            -1.0,
            1.0,
            -1.0,
            1.0,
            -1.0,
            1.0,
            -1.0,
            1.0,
            -1.0,
          ]),
        );

        final pcmTarget = Int16List(12);
        interleaver.interleavePcm16To([left1, right1], pcmTarget);
        expect(
          pcmTarget,
          equals([
            0,
            -32767,
            8192,
            32767,
            16384,
            -16384,
            24575,
            16384,
            32767,
            0,
            -32767,
            8192,
          ]),
        );

        final recLeft = Float32List(6);
        final recRight = Float32List(6);
        interleaver.deinterleaveFloatsFrom(target, [recLeft, recRight]);
        expect(recLeft, equals(left2));
        expect(recRight, equals(right2));

        // Partial vectorSize (e.g. underrun frame count < interleaver.vectorSize)
        final partialLeft = Float32List(6);
        final partialRight = Float32List(6);
        interleaver.deinterleaveFloatsFrom(
          target,
          [partialLeft, partialRight],
          vectorSize: 5,
        );
        expect(partialLeft, equals([1.0, 1.0, 1.0, 1.0, 1.0, 0.0]));
        expect(partialRight, equals([-1.0, -1.0, -1.0, -1.0, -1.0, 0.0]));
      },
    );
  });
}
