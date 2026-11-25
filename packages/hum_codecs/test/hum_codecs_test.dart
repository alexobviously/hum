import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_codecs/native.dart';
import 'package:test/test.dart';

bool _hasFfmpeg() {
  try {
    final res = Process.runSync('ffmpeg', ['-version']);
    return res.exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  group('hum_codecs (native Symphonia)', () {
    test('decodes stereo float32 and pcm16 WAV synchronously and asynchronously', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(context: context);
      final oscL = SineOscillator(frequency: const .value(440.0));
      final oscR = SineOscillator(frequency: const .value(880.0));
      host.setGraph(root: Out.stereo(left: oscL.outlet, right: oscR.outlet));

      final wavBytes = await host.exportWav(
        duration: const Duration(milliseconds: 20),
        format: .pcm16,
      );
      await host.dispose();

      final reference = readWav(wavBytes);
      final syncDecoded = decodeAudioSync(wavBytes, hint: 'wav');
      final asyncDecoded = await decodeAudio(wavBytes, hint: 'wav');

      for (final decoded in [syncDecoded, asyncDecoded]) {
        expect(decoded.sampleRate, equals(48000));
        expect(decoded.numChannels, equals(2));
        expect(decoded.length, equals(reference.length));
        for (int i = 0; i < 64; i++) {
          expect(decoded[0][i], closeTo(reference[0][i], 1e-4));
          expect(decoded[1][i], closeTo(reference[1][i], 1e-4));
        }
      }
    });

    test('decodes compressed MP3, FLAC, and Ogg Vorbis files and plays via SamplePlayer', () async {
      if (!_hasFfmpeg()) {
        markTestSkipped('ffmpeg not available to generate compressed fixtures');
        return;
      }

      const context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = SyncAudioHost(context: context);
      final osc = SineOscillator(frequency: const .value(440.0));
      host.setGraph(root: Out.mono(osc.outlet));

      final tmpDir = await Directory.systemTemp.createTemp('hum_codecs_test_');
      try {
        final wavPath = '${tmpDir.path}/tone.wav';
        await host.exportWav(
          path: wavPath,
          duration: const Duration(milliseconds: 100),
          format: .pcm16,
        );

        for (final ext in ['mp3', 'flac', 'ogg']) {
          final encodedPath = '${tmpDir.path}/tone.$ext';
          final res = Process.runSync('ffmpeg', [
            '-y',
            '-loglevel',
            'error',
            '-i',
            wavPath,
            encodedPath,
          ]);
          expect(
            res.exitCode,
            equals(0),
            reason: 'ffmpeg failed for .$ext: ${res.stderr}',
          );

          final buffer = await loadAudio(encodedPath);
          expect(buffer.sampleRate, equals(44100));
          expect(buffer.numChannels, equals(1));
          expect(buffer.length, greaterThan(4000));

          // Verify decoded audio is non-silent and playable via SamplePlayer.
          final handle = host.loadBuffer(buffer);
          final player = SamplePlayer(buffer: handle);
          expect(host.setGraph(root: Out.mono(player.outlet)), isEmpty);
          // Render past MP3 encoder priming delay (~1105 samples).
          final rendered = await host.renderBlocks(40);
          double peak = 0.0;
          for (final block in rendered) {
            for (final s in block) {
              if (s.abs() > peak) peak = s.abs();
            }
          }
          expect(peak, greaterThan(0.5), reason: 'decoded .$ext was silent');
          host.unloadBuffer(handle);
        }
      } finally {
        await tmpDir.delete(recursive: true);
        await host.dispose();
      }
    });

    test('throws FormatException on empty or invalid bytes', () async {
      expect(() => decodeAudioSync(Uint8List(0)), throwsFormatException);
      expect(
        () => decodeAudioSync(Uint8List.fromList('not audio'.codeUnits), hint: 'mp3'),
        throwsFormatException,
      );
      await expectLater(
        decodeAudio(Uint8List(0)),
        throwsFormatException,
      );
      await expectLater(
        decodeAudio(Uint8List.fromList('not audio'.codeUnits)),
        throwsFormatException,
      );
    });
  });
}
