import 'dart:typed_data';

import '../nodes/utils/clamp.dart';

// TODO: look at doing SIMD for all this stuff

/// Interleaves multi-channel audio from [channels] into the pre-allocated [target] buffer.
///
/// If [vectorSize] is omitted, it defaults to the length of the first channel.
/// Fast paths are provided for mono (single channel) and stereo (two channels).
@pragma('vm:prefer-inline')
void interleaveFloats(
  List<Float32List> channels,
  Float32List target, {
  int? vectorSize,
}) {
  if (channels.isEmpty) return;
  final numChannels = channels.length;
  final size = vectorSize ?? channels[0].length;

  if (numChannels == 1) {
    target.setRange(0, size, channels[0]);
    return;
  }

  if (numChannels == 2) {
    final left = channels[0];
    final right = channels[1];
    int writeIdx = 0;
    for (int s = 0; s < size; s++) {
      target[writeIdx++] = left[s];
      target[writeIdx++] = right[s];
    }
    return;
  }

  int writeIdx = 0;
  for (int s = 0; s < size; s++) {
    for (int c = 0; c < numChannels; c++) {
      target[writeIdx++] = channels[c][s];
    }
  }
}

/// Interleaves multi-channel float audio from [channels] into 16-bit integer PCM in [target].
///
/// Input float values are clamped to `[-1.0, 1.0]` and scaled to `[-32768, 32767]`.
/// Fast paths are provided for mono and stereo channels.
@pragma('vm:prefer-inline')
void interleavePcm16(
  List<Float32List> channels,
  Int16List target, {
  int? vectorSize,
}) {
  if (channels.isEmpty) return;
  final numChannels = channels.length;
  final size = vectorSize ?? channels[0].length;

  if (numChannels == 1) {
    final ch = channels[0];
    for (int s = 0; s < size; s++) {
      final sample = ch[s].fastClamp(-1.0, 1.0);
      target[s] = (sample * 32767.0).round();
    }
    return;
  }

  if (numChannels == 2) {
    final left = channels[0];
    final right = channels[1];
    int writeIdx = 0;
    for (int s = 0; s < size; s++) {
      final sampleL = left[s].fastClamp(-1.0, 1.0);
      final sampleR = right[s].fastClamp(-1.0, 1.0);
      target[writeIdx++] = (sampleL * 32767.0).round();
      target[writeIdx++] = (sampleR * 32767.0).round();
    }
    return;
  }

  int writeIdx = 0;
  for (int s = 0; s < size; s++) {
    for (int c = 0; c < numChannels; c++) {
      final sample = channels[c][s].fastClamp(-1.0, 1.0);
      target[writeIdx++] = (sample * 32767.0).round();
    }
  }
}

/// De-interleaves [interleaved] audio into the pre-allocated [targetChannels] buffers.
///
/// Fast paths are provided for mono and stereo channels.
@pragma('vm:prefer-inline')
void deinterleaveFloats(
  Float32List interleaved,
  List<Float32List> targetChannels, {
  int? vectorSize,
}) {
  if (targetChannels.isEmpty) return;
  final numChannels = targetChannels.length;
  final size = vectorSize ?? targetChannels[0].length;

  if (numChannels == 1) {
    targetChannels[0].setRange(0, size, interleaved);
    return;
  }

  if (numChannels == 2) {
    final left = targetChannels[0];
    final right = targetChannels[1];
    int readIdx = 0;
    for (int s = 0; s < size; s++) {
      left[s] = interleaved[readIdx++];
      right[s] = interleaved[readIdx++];
    }
    return;
  }

  int readIdx = 0;
  for (int s = 0; s < size; s++) {
    for (int c = 0; c < numChannels; c++) {
      targetChannels[c][s] = interleaved[readIdx++];
    }
  }
}

/// De-interleaves 16-bit integer PCM from [interleaved] into float audio in [targetChannels].
///
/// Input integer PCM values in `[-32768, 32767]` are converted to float in `[-1.0, 1.0]`.
/// Fast paths are provided for mono and stereo channels.
@pragma('vm:prefer-inline')
void deinterleavePcm16(
  Int16List interleaved,
  List<Float32List> targetChannels, {
  int? vectorSize,
}) {
  if (targetChannels.isEmpty) return;
  final numChannels = targetChannels.length;
  final size = vectorSize ?? targetChannels[0].length;
  const double invScale = 1.0 / 32768.0;

  if (numChannels == 1) {
    final target = targetChannels[0];
    for (int s = 0; s < size; s++) {
      target[s] = interleaved[s] * invScale;
    }
    return;
  }

  if (numChannels == 2) {
    final left = targetChannels[0];
    final right = targetChannels[1];
    int readIdx = 0;
    for (int s = 0; s < size; s++) {
      left[s] = interleaved[readIdx++] * invScale;
      right[s] = interleaved[readIdx++] * invScale;
    }
    return;
  }

  int readIdx = 0;
  for (int s = 0; s < size; s++) {
    for (int c = 0; c < numChannels; c++) {
      targetChannels[c][s] = interleaved[readIdx++] * invScale;
    }
  }
}

/// A reusable, zero-allocation container that manages pre-allocated buffers and byte
/// views for interleaving multi-channel audio blocks.
class BufferInterleaver({
  required final int numChannels,
  required final int vectorSize,
}) {
  final int totalSamples = numChannels * vectorSize;

  Float32List? _floatBuffer;
  Uint8List? _floatByteView;

  Int16List? _pcm16Buffer;
  Uint8List? _pcm16ByteView;

  /// The pre-allocated interleaved [Float32List] buffer (lazily initialized).
  Float32List get floatBuffer => _floatBuffer ??= Float32List(totalSamples);

  /// A pre-cached [Uint8List] byte view over [floatBuffer].
  Uint8List get floatByteView =>
      _floatByteView ??= floatBuffer.buffer.asUint8List(
        floatBuffer.offsetInBytes,
        floatBuffer.lengthInBytes,
      );

  /// The pre-allocated interleaved [Int16List] buffer (lazily initialized).
  Int16List get pcm16Buffer => _pcm16Buffer ??= Int16List(totalSamples);

  /// A pre-cached [Uint8List] byte view over [pcm16Buffer].
  Uint8List get pcm16ByteView =>
      _pcm16ByteView ??= pcm16Buffer.buffer.asUint8List(
        pcm16Buffer.offsetInBytes,
        pcm16Buffer.lengthInBytes,
      );

  /// Interleaves [channels] into [floatBuffer] and returns [floatByteView].
  ///
  /// Zero heap allocations occur during this call.
  @pragma('vm:prefer-inline')
  Uint8List interleaveFloat32Bytes(List<Float32List> channels) {
    interleaveFloats(channels, floatBuffer, vectorSize: vectorSize);
    return floatByteView;
  }

  /// Interleaves [channels] into [pcm16Buffer] and returns [pcm16ByteView].
  ///
  /// Zero heap allocations occur during this call.
  @pragma('vm:prefer-inline')
  Uint8List interleavePcm16Bytes(List<Float32List> channels) {
    interleavePcm16(channels, pcm16Buffer, vectorSize: vectorSize);
    return pcm16ByteView;
  }
}
