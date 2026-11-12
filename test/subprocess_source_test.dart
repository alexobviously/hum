import 'dart:io';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:test/test.dart';

void main() {
  group('SubprocessSource', () {
    test('declares expected outlets and zero inlets for mono and stereo', () {
      final mono = SubprocessSource(executable: 'sox', numChannels: 1);
      expect(mono.inlets, isEmpty);
      expect(mono.outlets.length, equals(1));
      expect(mono.outlet, equals(mono.outlets[0]));
      expect(mono.channels.length, equals(1));

      final stereo = SubprocessSource(executable: 'ffmpeg', numChannels: 2);
      expect(stereo.inlets, isEmpty);
      expect(stereo.outlets.length, equals(2));
      expect(stereo.left, equals(stereo.outlets[0]));
      expect(stereo.right, equals(stereo.outlets[1]));
      expect(stereo.channels.length, equals(2));
    });

    test('validates parameters and returns diagnostics', () {
      final invalidChannels = SubprocessSource(
        executable: 'sox',
        numChannels: 0,
      );
      expect(invalidChannels.errors, isNotEmpty);
      expect(invalidChannels.errors.first.message, contains('numChannels'));

      final emptyExec = SubprocessSource(executable: '   ');
      expect(emptyExec.errors, isNotEmpty);
      expect(emptyExec.errors.first.message, contains('executable'));

      final valid = SubprocessSource(executable: 'sox', numChannels: 1);
      expect(valid.errors, isEmpty);
    });

    test('named constructors configure appropriate arguments', () {
      final soxSource = SubprocessSource.sox(
        numChannels: 2,
        sampleRate: 48000,
        format: WavFormat.pcm16,
      );
      expect(soxSource.executable, equals('sox'));
      expect(soxSource.numChannels, equals(2));
      expect(soxSource.format, equals(WavFormat.pcm16));
      expect(soxSource.arguments, contains('-r'));
      expect(soxSource.arguments, contains('48000'));
      expect(soxSource.arguments, contains('-c'));
      expect(soxSource.arguments, contains('2'));
      expect(soxSource.arguments, contains('16'));

      final ffmpegSource = SubprocessSource.ffmpeg(
        numChannels: 1,
        sampleRate: 44100,
        format: WavFormat.float32,
      );
      expect(ffmpegSource.executable, equals('ffmpeg'));
      expect(ffmpegSource.numChannels, equals(1));
      expect(ffmpegSource.arguments, contains('f32le'));
      expect(ffmpegSource.arguments, contains('-ar'));
      expect(ffmpegSource.arguments, contains('44100'));

      final micSource = SubprocessSource.mic();
      expect(micSource.numChannels, equals(1));
      expect(micSource.executable, isNotEmpty);
    });

    test('canUpdate enforces identical executable, format, and arguments', () {
      final a = SubprocessSource(
        executable: 'sox',
        arguments: ['-d'],
        numChannels: 1,
      );
      final b = SubprocessSource(
        executable: 'sox',
        arguments: ['-d'],
        numChannels: 1,
      );
      final c = SubprocessSource(
        executable: 'ffmpeg',
        arguments: ['-d'],
        numChannels: 1,
      );
      final d = SubprocessSource(
        executable: 'sox',
        arguments: ['-i', 'file.wav'],
        numChannels: 1,
      );

      expect(a.canUpdate(b), isTrue);
      expect(a.canUpdate(c), isFalse);
      expect(a.canUpdate(d), isFalse);
    });

    test(
      'streams synthesized audio from sox process into AudioPipeline',
      () async {
        if (!File('/opt/homebrew/bin/sox').existsSync() &&
            !File('/usr/local/bin/sox').existsSync()) {
          return;
        }

        const sampleRate = 44100;
        const vectorSize = 64;
        final context = ProcessContext(
          sampleRate: sampleRate,
          vectorSize: vectorSize,
        );

        final source = SubprocessSource(
          executable: 'sox',
          arguments: [
            '-n',
            '-t',
            'raw',
            '-r',
            '$sampleRate',
            '-c',
            '1',
            '-b',
            '32',
            '-e',
            'floating-point',
            '-',
            'synth',
            '0.1',
            'sine',
            '440',
          ],
          numChannels: 1,
          format: WavFormat.float32,
        );

        final pipeline = compilePipeline(
          root: source,
          context: context,
        ).pipeline!;
        final proc = pipeline.processorOf(source);
        await proc.ensureStarted();

        // Allow child process to start streaming
        await Future.delayed(const Duration(milliseconds: 50));

        // Process blocks and verify non-zero samples arrive
        bool foundNonZero = false;
        for (int i = 0; i < 20; i++) {
          pipeline.process();
          for (int s = 0; s < vectorSize; s++) {
            if (pipeline.outputs[0][s].abs() > 0.01) {
              foundNonZero = true;
              break;
            }
          }
          if (foundNonZero) break;
          await Future.delayed(const Duration(milliseconds: 10));
        }

        expect(foundNonZero, isTrue);
        await proc.close();
      },
    );

    test(
      'streams synthesized audio from ffmpeg process into AudioPipeline',
      () async {
        if (!File('/opt/homebrew/bin/ffmpeg').existsSync() &&
            !File('/usr/local/bin/ffmpeg').existsSync()) {
          return;
        }

        const sampleRate = 44100;
        const vectorSize = 64;
        final context = ProcessContext(
          sampleRate: sampleRate,
          vectorSize: vectorSize,
        );

        final source = SubprocessSource(
          executable: 'ffmpeg',
          arguments: [
            '-loglevel',
            'quiet',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:duration=0.1',
            '-f',
            'f32le',
            '-ac',
            '1',
            '-ar',
            '$sampleRate',
            '-',
          ],
          numChannels: 1,
          format: WavFormat.float32,
        );

        final pipeline = compilePipeline(
          root: source,
          context: context,
        ).pipeline!;
        final proc = pipeline.processorOf(source);
        await proc.ensureStarted();

        // Allow child process to start streaming
        await Future.delayed(const Duration(milliseconds: 50));

        bool foundNonZero = false;
        for (int i = 0; i < 20; i++) {
          pipeline.process();
          for (int s = 0; s < vectorSize; s++) {
            if (pipeline.outputs[0][s].abs() > 0.01) {
              foundNonZero = true;
              break;
            }
          }
          if (foundNonZero) break;
          await Future.delayed(const Duration(milliseconds: 10));
        }

        expect(foundNonZero, isTrue);
        await proc.close();
      },
    );
  });
}
