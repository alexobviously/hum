import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Decodes a RIFF/WAVE byte buffer into a planar 32-bit float [AudioBuffer].
///
/// Pure Dart (no `dart:io`), so it works on Desktop, Mobile (including Flutter
/// `rootBundle.load`), and Web/Wasm.
///
/// Supports:
/// - Uncompressed PCM (8-bit unsigned, 16-bit, 24-bit, and 32-bit signed)
/// - IEEE floating-point (32-bit and 64-bit)
/// - `WAVE_FORMAT_EXTENSIBLE` wrappers around PCM or IEEE float
/// - Arbitrary non-audio metadata chunks (`LIST`, `JUNK`, `bext`, `smpl`, etc.)
///
/// Throws [FormatException] if [bytes] is not a valid or supported WAV file.
AudioBuffer readWav(Uint8List bytes) {
  if (bytes.lengthInBytes < 12) {
    throw const FormatException('WAV data too short to contain RIFF header.');
  }

  final view = ByteData.sublistView(bytes);
  if (!_matchesAscii(bytes, 0, 'RIFF') || !_matchesAscii(bytes, 8, 'WAVE')) {
    throw const FormatException('Invalid WAV header: expected RIFF/WAVE.');
  }

  int? audioFormat;
  int? numChannels;
  int? sampleRate;
  int? bitsPerSample;
  int? dataOffset;
  int? dataSize;

  int offset = 12;
  while (offset + 8 <= bytes.lengthInBytes) {
    final chunkSize = view.getUint32(offset + 4, Endian.little);
    final chunkDataOffset = offset + 8;

    if (_matchesAscii(bytes, offset, 'fmt ')) {
      if (chunkSize < 16 || chunkDataOffset + 16 > bytes.lengthInBytes) {
        throw const FormatException('Truncated WAV fmt chunk.');
      }
      var formatTag = view.getUint16(chunkDataOffset, Endian.little);
      numChannels = view.getUint16(chunkDataOffset + 2, Endian.little);
      sampleRate = view.getUint32(chunkDataOffset + 4, Endian.little);
      bitsPerSample = view.getUint16(chunkDataOffset + 14, Endian.little);

      // WAVE_FORMAT_EXTENSIBLE (0xFFFE): real format tag is the first 2 bytes
      // of the 16-byte SubFormat GUID at chunkDataOffset + 24.
      if (formatTag == 0xFFFE) {
        if (chunkSize < 40 || chunkDataOffset + 26 > bytes.lengthInBytes) {
          throw const FormatException(
            'Truncated WAVE_FORMAT_EXTENSIBLE chunk.',
          );
        }
        formatTag = view.getUint16(chunkDataOffset + 24, Endian.little);
      }
      audioFormat = formatTag;
    } else if (_matchesAscii(bytes, offset, 'data')) {
      dataOffset = chunkDataOffset;
      final remaining = bytes.lengthInBytes - chunkDataOffset;
      dataSize = chunkSize <= remaining ? chunkSize : remaining;
    }

    // RIFF chunks are padded to an even byte boundary.
    final paddedSize = chunkSize + (chunkSize & 1);
    final nextOffset = chunkDataOffset + paddedSize;
    if (nextOffset <= offset) {
      throw const FormatException('Invalid WAV chunk size.');
    }
    offset = nextOffset;
  }

  if (audioFormat == null ||
      numChannels == null ||
      sampleRate == null ||
      bitsPerSample == null) {
    throw const FormatException('WAV file is missing a fmt chunk.');
  }
  if (dataOffset == null || dataSize == null) {
    throw const FormatException('WAV file is missing a data chunk.');
  }
  if (numChannels <= 0 || sampleRate <= 0) {
    throw FormatException(
      'Invalid WAV stream parameters: ${numChannels}ch @ $sampleRate Hz.',
    );
  }
  if (bitsPerSample % 8 != 0 || bitsPerSample <= 0) {
    throw FormatException('Unsupported WAV bit depth: $bitsPerSample.');
  }

  final bytesPerSample = bitsPerSample ~/ 8;
  final blockAlign = bytesPerSample * numChannels;
  final numFrames = dataSize ~/ blockAlign;

  final channels = List.generate(
    numChannels,
    (_) => Float32List(numFrames),
    growable: false,
  );

  switch ((audioFormat, bitsPerSample)) {
    case (1, 8):
      int pos = dataOffset;
      for (int i = 0; i < numFrames; i++) {
        for (int ch = 0; ch < numChannels; ch++) {
          channels[ch][i] = (bytes[pos++] - 128) / 128.0;
        }
      }
    case (1, 16):
      int pos = dataOffset;
      for (int i = 0; i < numFrames; i++) {
        for (int ch = 0; ch < numChannels; ch++) {
          channels[ch][i] = view.getInt16(pos, Endian.little) / 32768.0;
          pos += 2;
        }
      }
    case (1, 24):
      int pos = dataOffset;
      for (int i = 0; i < numFrames; i++) {
        for (int ch = 0; ch < numChannels; ch++) {
          int sample =
              bytes[pos] | (bytes[pos + 1] << 8) | (bytes[pos + 2] << 16);
          if ((sample & 0x800000) != 0) {
            sample |= ~0xFFFFFF;
          }
          channels[ch][i] = sample / 8388608.0;
          pos += 3;
        }
      }
    case (1, 32):
      int pos = dataOffset;
      for (int i = 0; i < numFrames; i++) {
        for (int ch = 0; ch < numChannels; ch++) {
          channels[ch][i] = view.getInt32(pos, Endian.little) / 2147483648.0;
          pos += 4;
        }
      }
    case (3, 32):
      int pos = dataOffset;
      for (int i = 0; i < numFrames; i++) {
        for (int ch = 0; ch < numChannels; ch++) {
          channels[ch][i] = view.getFloat32(pos, Endian.little);
          pos += 4;
        }
      }
    case (3, 64):
      int pos = dataOffset;
      for (int i = 0; i < numFrames; i++) {
        for (int ch = 0; ch < numChannels; ch++) {
          channels[ch][i] = view.getFloat64(pos, Endian.little);
          pos += 8;
        }
      }
    default:
      throw FormatException(
        'Unsupported WAV format: tag=$audioFormat, bitsPerSample=$bitsPerSample.',
      );
  }

  return AudioBuffer(channels: channels, sampleRate: sampleRate);
}

bool _matchesAscii(Uint8List bytes, int offset, String ascii) {
  if (offset + ascii.length > bytes.lengthInBytes) return false;
  for (int i = 0; i < ascii.length; i++) {
    if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}
