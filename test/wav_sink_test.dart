import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('WavSink', () {
    test('WavSink.memory records audio and builds valid WAV in memory', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final sine = SineOscillator(frequency: .value(440));
      final pan = StereoPan(input: sine.outlet, pan: .value(0.0));
      final sink = WavSink.memory(
        channels: [pan.left, pan.right],
        format: WavFormat.pcm16,
      );

      final pipeline = compilePipeline(root: sink, context: context).pipeline!;
      // Process 5 blocks
      for (int i = 0; i < 5; i++) {
        pipeline.process();
      }

      final proc = pipeline.processorOf(sink);
      final bytes = proc.close();

      expect(bytes, isNotNull);
      // 5 blocks * 64 samples * 2 channels * 2 bytes/sample (pcm16) = 1280 bytes + 44 header = 1324 bytes
      expect(bytes!.length, equals(1324));

      // Verify header magic
      final byteData = ByteData.sublistView(bytes);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), equals('RIFF'));
      expect(String.fromCharCodes(bytes.sublist(8, 12)), equals('WAVE'));
      expect(String.fromCharCodes(bytes.sublist(12, 16)), equals('fmt '));
      expect(String.fromCharCodes(bytes.sublist(36, 40)), equals('data'));

      // Check channels (index 22) and sample rate (index 24)
      expect(byteData.getUint16(20, Endian.little), equals(1)); // PCM format
      expect(byteData.getUint16(22, Endian.little), equals(2)); // Stereo
      expect(
        byteData.getUint32(24, Endian.little),
        equals(44100),
      ); // Sample rate
      expect(
        byteData.getUint32(40, Endian.little),
        equals(1280),
      ); // Data length
    });

    test('WavSink.file streams audio directly to a file', () {
      final tmpFile = File('tmp/test_sink.wav');
      if (tmpFile.existsSync()) tmpFile.deleteSync();

      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final sine = SineOscillator(frequency: .value(440));
      final sink = WavSink.file(
        channels: [sine.outlet],
        path: tmpFile.path,
        format: WavFormat.float32,
      );

      final pipeline = compilePipeline(root: sink, context: context).pipeline!;
      // Process 10 blocks
      for (int i = 0; i < 10; i++) {
        pipeline.process();
      }

      final proc = pipeline.processorOf(sink);
      proc.close();

      expect(tmpFile.existsSync(), isTrue);
      final fileBytes = tmpFile.readAsBytesSync();

      // 10 blocks * 64 samples * 1 channel * 4 bytes/sample (float32) = 2560 bytes + 44 header = 2604 bytes
      expect(fileBytes.length, equals(2604));

      final byteData = ByteData.sublistView(fileBytes);
      expect(String.fromCharCodes(fileBytes.sublist(0, 4)), equals('RIFF'));
      expect(String.fromCharCodes(fileBytes.sublist(8, 12)), equals('WAVE'));
      expect(
        byteData.getUint16(20, Endian.little),
        equals(3),
      ); // float32 format
      expect(byteData.getUint16(22, Endian.little), equals(1)); // Mono
      expect(
        byteData.getUint32(40, Endian.little),
        equals(2560),
      ); // Data length

      // Clean up
      tmpFile.deleteSync();
    });
  });
}
