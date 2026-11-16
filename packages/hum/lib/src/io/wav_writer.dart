import 'dart:typed_data';

enum WavFormat({
  required final int code,
  required final int bitsPerSample,
}) {
  pcm16(code: 1, bitsPerSample: 16),
  float32(code: 3, bitsPerSample: 32),
}

ByteData buildWavHeader({
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
