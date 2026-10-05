import 'dart:io';
import 'dart:typed_data';

enum WavFormat {
  pcm16(code: 1, bitsPerSample: 16),
  float32(code: 3, bitsPerSample: 32);

  final int code;
  final int bitsPerSample;

  const WavFormat({required this.code, required this.bitsPerSample});
}

/// Writes audio blocks to a WAV file as 16-bit integer PCM or 32-bit float PCM.
void writeWav(
  String path,
  List<Float32List> audio, {
  int sampleRate = 44100,
  int numChannels = 1,
  WavFormat format = .float32,
}) {
  int totalSamples = 0;
  for (final block in audio) {
    totalSamples += block.length;
  }

  final bytesPerSample = format.bitsPerSample ~/ 8;
  final dataSize = totalSamples * bytesPerSample;

  final header = _buildWavHeader(
    dataSize: dataSize,
    sampleRate: sampleRate,
    numChannels: numChannels,
    format: format,
  );

  final builder = BytesBuilder(copy: false);
  builder.add(header.buffer.asUint8List());

  switch (format) {
    case WavFormat.float32:
      for (final block in audio) {
        builder.add(
          block.buffer.asUint8List(block.offsetInBytes, block.lengthInBytes),
        );
      }
    case WavFormat.pcm16:
      for (final block in audio) {
        final pcm16 = Int16List(block.length);
        for (int i = 0; i < block.length; i++) {
          final sample = block[i].clamp(-1.0, 1.0);
          pcm16[i] = (sample * 32767.0).round();
        }
        builder.add(pcm16.buffer.asUint8List());
      }
  }

  File(path).writeAsBytesSync(builder.takeBytes());
}

ByteData _buildWavHeader({
  required int dataSize,
  required int sampleRate,
  required int numChannels,
  required WavFormat format,
}) {
  final header = ByteData(44);

  // RIFF Chunk Descriptor
  header.setUint8(0, 0x52); // 'R'
  header.setUint8(1, 0x49); // 'I'
  header.setUint8(2, 0x46); // 'F'
  header.setUint8(3, 0x46); // 'F'
  header.setUint32(4, dataSize + 36, .little);
  header.setUint8(8, 0x57); // 'W'
  header.setUint8(9, 0x41); // 'A'
  header.setUint8(10, 0x56); // 'V'
  header.setUint8(11, 0x45); // 'E'

  // "fmt " Sub-chunk
  header.setUint8(12, 0x66); // 'f'
  header.setUint8(13, 0x6D); // 'm'
  header.setUint8(14, 0x74); // 't'
  header.setUint8(15, 0x20); // ' '
  header.setUint32(16, 16, .little); // Subchunk1Size (16 for PCM)
  header.setUint16(20, format.code, .little);
  header.setUint16(22, numChannels, .little);
  header.setUint32(24, sampleRate, .little);

  final byteRate = sampleRate * numChannels * (format.bitsPerSample ~/ 8);
  final blockAlign = numChannels * (format.bitsPerSample ~/ 8);
  header.setUint32(28, byteRate, .little);
  header.setUint16(32, blockAlign, .little);
  header.setUint16(34, format.bitsPerSample, .little);

  // "data" Sub-chunk
  header.setUint8(36, 0x64); // 'd'
  header.setUint8(37, 0x61); // 'a'
  header.setUint8(38, 0x74); // 't'
  header.setUint8(39, 0x61); // 'a'
  header.setUint32(40, dataSize, .little);

  return header;
}
