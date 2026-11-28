@TestOn('browser')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum_codecs/hum_codecs.dart';
import 'package:test/test.dart';

Uint8List _makeStereoPcm16Wav(int sampleRate, int numFrames) {
  final dataSize = numFrames * 4;
  final header = buildWavHeader(
    dataSize: dataSize,
    sampleRate: sampleRate,
    numChannels: 2,
    format: .pcm16,
  );
  final out = Uint8List(44 + dataSize);
  out.setRange(0, 44, header.buffer.asUint8List(0, 44));

  final view = ByteData.sublistView(out, 44);
  for (int i = 0; i < numFrames; i++) {
    final l = math.sin(2.0 * math.pi * 440.0 * i / sampleRate);
    final r = math.sin(2.0 * math.pi * 880.0 * i / sampleRate);
    view.setInt16(i * 4, (l * 32767.0).round(), Endian.little);
    view.setInt16(i * 4 + 2, (r * 32767.0).round(), Endian.little);
  }
  return out;
}

void main() {
  group('hum_codecs (browser AudioContext.decodeAudioData)', () {
    test(
      'decodes stereo WAV into planar AudioBuffer without neutering input',
      () async {
        final wavBytes = _makeStereoPcm16Wav(48000, 1024);
        final originalFirstByte = wavBytes[0];

        final buffer = await decodeAudio(wavBytes, hint: 'wav');

        // Caller's Uint8List must remain intact (not detached by decodeAudioData).
        expect(wavBytes.length, equals(44 + 1024 * 4));
        expect(wavBytes[0], equals(originalFirstByte));

        expect(buffer.numChannels, equals(2));
        expect(buffer.sampleRate, greaterThan(0));
        expect(buffer.length, greaterThan(0));

        // Verify decoded audio is non-silent on both channels.
        double peakL = 0.0;
        double peakR = 0.0;
        for (int i = 0; i < buffer.length; i++) {
          final l = buffer[0][i].abs();
          final r = buffer[1][i].abs();
          if (l > peakL) peakL = l;
          if (r > peakR) peakR = r;
        }
        expect(peakL, greaterThan(0.8));
        expect(peakR, greaterThan(0.8));
      },
    );

    test('throws FormatException on empty or invalid bytes', () async {
      await expectLater(decodeAudio(Uint8List(0)), throwsFormatException);
      await expectLater(
        decodeAudio(Uint8List.fromList('not audio'.codeUnits)),
        throwsFormatException,
      );
    });
  });
}
