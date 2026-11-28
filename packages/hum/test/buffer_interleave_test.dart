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
      'interleavePcm16 replaces NaN and Infinity with 0 without throwing',
      () {
        final ch0 = Float32List.fromList([
          double.nan,
          double.infinity,
          double.negativeInfinity,
          0.5,
        ]);
        final target = Int16List(4);

        interleavePcm16([ch0], target);

        expect(target, equals([0, 0, 0, 16384]));
      },
    );

    test(
      'sanitizeAudioSample and sanitizeAudioOutputs clamp and zero non-finite',
      () {
        expect(sanitizeAudioSample(0.25), equals(0.25));
        expect(sanitizeAudioSample(-0.75), equals(-0.75));
        expect(sanitizeAudioSample(1.0), equals(1.0));
        expect(sanitizeAudioSample(-1.0), equals(-1.0));
        expect(sanitizeAudioSample(4.5), equals(1.0));
        expect(sanitizeAudioSample(-3.2), equals(-1.0));
        expect(sanitizeAudioSample(double.nan), equals(0.0));
        expect(sanitizeAudioSample(double.infinity), equals(0.0));
        expect(sanitizeAudioSample(double.negativeInfinity), equals(0.0));

        final left = Float32List.fromList([
          0.25,
          2.5,
          -2.5,
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ]);
        final right = Float32List.fromList([
          -0.5,
          1.0,
          -1.0,
          10.0,
          -10.0,
          double.nan,
        ]);

        sanitizeAudioOutputs([left, right]);

        expect(left, equals([0.25, 1.0, -1.0, 0.0, 0.0, 0.0]));
        expect(right, equals([-0.5, 1.0, -1.0, 1.0, -1.0, 0.0]));
      },
    );

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
  });
}
