import 'dart:typed_data';

import '../nodes/utils/clamp.dart';
import '../utils/simd.dart';

/// Interleaves multi-channel audio from [channels] into the pre-allocated [target] buffer.
///
/// If [vectorSize] is omitted, it defaults to the length of the first channel.
/// Fast paths (including 128-bit SIMD on supported platforms) are provided for
/// mono, stereo, and quad channels.
@pragma('vm:prefer-inline')
void interleaveFloats(
  List<Float32List> channels,
  Float32List target, {
  int? vectorSize,
}) {
  if (channels.isEmpty) return;
  final numChannels = channels.length;
  final size = vectorSize ?? channels[0].length;
  if (size <= 0) return;

  if (numChannels == 1) {
    target.setRange(0, size, channels[0]);
    return;
  }

  int start = 0;
  if (SIMD.isSupported && size >= 4 && SIMD.isAligned(target)) {
    final simdSize = size & ~3;
    if (numChannels == 2) {
      final left = channels[0];
      final right = channels[1];
      if (SIMD.isAligned(left) && SIMD.isAligned(right)) {
        SIMD.interleaveStereoFloats(
          SIMD.view(target, simdSize << 1),
          SIMD.view(left, simdSize),
          SIMD.view(right, simdSize),
          simdSize,
        );
        start = simdSize;
      }
    } else if (numChannels == 4) {
      final c0 = channels[0];
      final c1 = channels[1];
      final c2 = channels[2];
      final c3 = channels[3];
      if (SIMD.isAligned(c0) &&
          SIMD.isAligned(c1) &&
          SIMD.isAligned(c2) &&
          SIMD.isAligned(c3)) {
        SIMD.interleaveQuadFloats(
          SIMD.view(target, simdSize << 2),
          SIMD.view(c0, simdSize),
          SIMD.view(c1, simdSize),
          SIMD.view(c2, simdSize),
          SIMD.view(c3, simdSize),
          simdSize,
        );
        start = simdSize;
      }
    }
  }

  if (start < size) {
    _interleaveFloatsScalar(channels, target, numChannels, start, size);
  }
}

/// Interleaves multi-channel float audio from [channels] into 16-bit integer PCM in [target].
///
/// Input float values are clamped to `[-1.0, 1.0]` and scaled to `[-32768, 32767]`.
/// Fast paths (including 128-bit SIMD on supported platforms) are provided for
/// mono, stereo, and multi-channel audio.
@pragma('vm:prefer-inline')
void interleavePcm16(
  List<Float32List> channels,
  Int16List target, {
  int? vectorSize,
}) {
  if (channels.isEmpty) return;
  final numChannels = channels.length;
  final size = vectorSize ?? channels[0].length;
  if (size <= 0) return;

  int start = 0;
  if (SIMD.isSupported && size >= 4) {
    final simdSize = size & ~3;
    if (numChannels == 1) {
      final ch = channels[0];
      if (SIMD.isAligned(ch)) {
        SIMD.interleaveMonoPcm16(
          target,
          SIMD.view(ch, simdSize),
          simdSize,
        );
        start = simdSize;
      }
    } else if (numChannels == 2) {
      final left = channels[0];
      final right = channels[1];
      if (SIMD.isAligned(left) && SIMD.isAligned(right)) {
        SIMD.interleaveStereoPcm16(
          target,
          SIMD.view(left, simdSize),
          SIMD.view(right, simdSize),
          simdSize,
        );
        start = simdSize;
      }
    } else if (_allAligned(channels)) {
      for (int c = 0; c < numChannels; c++) {
        SIMD.interleaveChannelPcm16(
          target,
          SIMD.view(channels[c], simdSize),
          c,
          numChannels,
          simdSize,
        );
      }
      start = simdSize;
    }
  }

  if (start < size) {
    _interleavePcm16Scalar(channels, target, numChannels, start, size);
  }
}

/// De-interleaves [interleaved] audio into the pre-allocated [targetChannels] buffers.
///
/// Fast paths (including 128-bit SIMD on supported platforms) are provided for
/// mono, stereo, and quad channels.
@pragma('vm:prefer-inline')
void deinterleaveFloats(
  Float32List interleaved,
  List<Float32List> targetChannels, {
  int? vectorSize,
}) {
  if (targetChannels.isEmpty) return;
  final numChannels = targetChannels.length;
  final size = vectorSize ?? targetChannels[0].length;
  if (size <= 0) return;

  if (numChannels == 1) {
    targetChannels[0].setRange(0, size, interleaved);
    return;
  }

  int start = 0;
  if (SIMD.isSupported && size >= 4 && SIMD.isAligned(interleaved)) {
    final simdSize = size & ~3;
    if (numChannels == 2) {
      final left = targetChannels[0];
      final right = targetChannels[1];
      if (SIMD.isAligned(left) && SIMD.isAligned(right)) {
        SIMD.deinterleaveStereoFloats(
          SIMD.view(interleaved, simdSize << 1),
          SIMD.view(left, simdSize),
          SIMD.view(right, simdSize),
          simdSize,
        );
        start = simdSize;
      }
    } else if (numChannels == 4) {
      final c0 = targetChannels[0];
      final c1 = targetChannels[1];
      final c2 = targetChannels[2];
      final c3 = targetChannels[3];
      if (SIMD.isAligned(c0) &&
          SIMD.isAligned(c1) &&
          SIMD.isAligned(c2) &&
          SIMD.isAligned(c3)) {
        SIMD.deinterleaveQuadFloats(
          SIMD.view(interleaved, simdSize << 2),
          SIMD.view(c0, simdSize),
          SIMD.view(c1, simdSize),
          SIMD.view(c2, simdSize),
          SIMD.view(c3, simdSize),
          simdSize,
        );
        start = simdSize;
      }
    }
  }

  if (start < size) {
    _deinterleaveFloatsScalar(
      interleaved,
      targetChannels,
      numChannels,
      start,
      size,
    );
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
  if (size <= 0) return;
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

@pragma('vm:prefer-inline')
bool _allAligned(List<Float32List> buffers) {
  for (int c = 0; c < buffers.length; c++) {
    if (!SIMD.isAligned(buffers[c])) return false;
  }
  return true;
}

@pragma('vm:prefer-inline')
void _interleaveFloatsScalar(
  List<Float32List> channels,
  Float32List target,
  int numChannels,
  int start,
  int size,
) {
  if (numChannels == 2) {
    final left = channels[0];
    final right = channels[1];
    int writeIdx = start << 1;
    for (int s = start; s < size; s++) {
      target[writeIdx++] = left[s];
      target[writeIdx++] = right[s];
    }
    return;
  }

  int writeIdx = start * numChannels;
  for (int s = start; s < size; s++) {
    for (int c = 0; c < numChannels; c++) {
      target[writeIdx++] = channels[c][s];
    }
  }
}

@pragma('vm:prefer-inline')
void _interleavePcm16Scalar(
  List<Float32List> channels,
  Int16List target,
  int numChannels,
  int start,
  int size,
) {
  if (numChannels == 1) {
    final ch = channels[0];
    for (int s = start; s < size; s++) {
      final sample = ch[s].fastClamp(-1.0, 1.0);
      target[s] = (sample * 32767.0).round();
    }
    return;
  }

  if (numChannels == 2) {
    final left = channels[0];
    final right = channels[1];
    int writeIdx = start << 1;
    for (int s = start; s < size; s++) {
      final sampleL = left[s].fastClamp(-1.0, 1.0);
      final sampleR = right[s].fastClamp(-1.0, 1.0);
      target[writeIdx++] = (sampleL * 32767.0).round();
      target[writeIdx++] = (sampleR * 32767.0).round();
    }
    return;
  }

  int writeIdx = start * numChannels;
  for (int s = start; s < size; s++) {
    for (int c = 0; c < numChannels; c++) {
      final sample = channels[c][s].fastClamp(-1.0, 1.0);
      target[writeIdx++] = (sample * 32767.0).round();
    }
  }
}

@pragma('vm:prefer-inline')
void _deinterleaveFloatsScalar(
  Float32List interleaved,
  List<Float32List> targetChannels,
  int numChannels,
  int start,
  int size,
) {
  if (numChannels == 2) {
    final left = targetChannels[0];
    final right = targetChannels[1];
    int readIdx = start << 1;
    for (int s = start; s < size; s++) {
      left[s] = interleaved[readIdx++];
      right[s] = interleaved[readIdx++];
    }
    return;
  }

  int readIdx = start * numChannels;
  for (int s = start; s < size; s++) {
    for (int c = 0; c < numChannels; c++) {
      targetChannels[c][s] = interleaved[readIdx++];
    }
  }
}

/// A reusable, zero-allocation container that manages pre-allocated buffers, byte
/// views, and cached SIMD vector views for interleaving multi-channel audio blocks.
class BufferInterleaver({
  required final int numChannels,
  required final int vectorSize,
}) {
  final int totalSamples = numChannels * vectorSize;
  late final int _simdSize = vectorSize > 0 ? (vectorSize & ~3) : 0;

  Float32List? _floatBuffer;
  Uint8List? _floatByteView;

  Int16List? _pcm16Buffer;
  Uint8List? _pcm16ByteView;

  // Cached SIMD views for zero-allocation steady-state interleaving
  Float32List? _lastTarget;
  SimdList? _lastTarget4;
  late final List<Float32List?> _lastChannels = List<Float32List?>.filled(
    numChannels,
    null,
  );
  late final List<SimdList?> _channels4 = List<SimdList?>.filled(
    numChannels,
    null,
  );

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

  @pragma('vm:prefer-inline')
  SimdList? _channelView(int index, Float32List channel) {
    if (identical(_lastChannels[index], channel)) {
      return _channels4[index];
    }
    _lastChannels[index] = channel;
    final view = SIMD.isAligned(channel) ? SIMD.view(channel, _simdSize) : null;
    _channels4[index] = view;
    return view;
  }

  @pragma('vm:prefer-inline')
  SimdList? _targetView(Float32List target) {
    if (identical(_lastTarget, target)) {
      return _lastTarget4;
    }
    _lastTarget = target;
    final view = SIMD.isAligned(target)
        ? SIMD.view(target, _simdSize * numChannels)
        : null;
    _lastTarget4 = view;
    return view;
  }

  /// Interleaves [channels] into [target] using cached SIMD views.
  ///
  /// Zero heap allocations occur in steady state when [channels] and [target]
  /// buffers are reused across blocks.
  @pragma('vm:prefer-inline')
  void interleaveFloatsTo(List<Float32List> channels, Float32List target) {
    if (numChannels <= 0 || vectorSize <= 0 || channels.isEmpty) return;

    if (numChannels == 1) {
      target.setRange(0, vectorSize, channels[0]);
      return;
    }

    int start = 0;
    if (SIMD.isSupported && _simdSize > 0) {
      final target4 = _targetView(target);
      if (target4 != null) {
        if (numChannels == 2) {
          final left4 = _channelView(0, channels[0]);
          final right4 = _channelView(1, channels[1]);
          if (left4 != null && right4 != null) {
            SIMD.interleaveStereoFloats(target4, left4, right4, _simdSize);
            start = _simdSize;
          }
        } else if (numChannels == 4) {
          final c0 = _channelView(0, channels[0]);
          final c1 = _channelView(1, channels[1]);
          final c2 = _channelView(2, channels[2]);
          final c3 = _channelView(3, channels[3]);
          if (c0 != null && c1 != null && c2 != null && c3 != null) {
            SIMD.interleaveQuadFloats(target4, c0, c1, c2, c3, _simdSize);
            start = _simdSize;
          }
        }
      }
    }

    if (start < vectorSize) {
      _interleaveFloatsScalar(
        channels,
        target,
        numChannels,
        start,
        vectorSize,
      );
    }
  }

  /// Interleaves and converts [channels] into 16-bit integer PCM in [target]
  /// using cached SIMD views.
  ///
  /// Zero heap allocations occur in steady state when [channels] and [target]
  /// buffers are reused across blocks.
  @pragma('vm:prefer-inline')
  void interleavePcm16To(List<Float32List> channels, Int16List target) {
    if (numChannels <= 0 || vectorSize <= 0 || channels.isEmpty) return;

    int start = 0;
    if (SIMD.isSupported && _simdSize > 0) {
      if (numChannels == 1) {
        final ch4 = _channelView(0, channels[0]);
        if (ch4 != null) {
          SIMD.interleaveMonoPcm16(target, ch4, _simdSize);
          start = _simdSize;
        }
      } else if (numChannels == 2) {
        final left4 = _channelView(0, channels[0]);
        final right4 = _channelView(1, channels[1]);
        if (left4 != null && right4 != null) {
          SIMD.interleaveStereoPcm16(target, left4, right4, _simdSize);
          start = _simdSize;
        }
      } else {
        bool allAligned = true;
        for (int c = 0; c < numChannels; c++) {
          if (_channelView(c, channels[c]) == null) {
            allAligned = false;
          }
        }
        if (allAligned) {
          for (int c = 0; c < numChannels; c++) {
            SIMD.interleaveChannelPcm16(
              target,
              _channels4[c]!,
              c,
              numChannels,
              _simdSize,
            );
          }
          start = _simdSize;
        }
      }
    }

    if (start < vectorSize) {
      _interleavePcm16Scalar(
        channels,
        target,
        numChannels,
        start,
        vectorSize,
      );
    }
  }

  /// De-interleaves [interleaved] audio into [targetChannels] using cached SIMD views.
  ///
  /// If [vectorSize] is omitted, it defaults to [this.vectorSize].
  /// Zero heap allocations occur in steady state when [interleaved] and
  /// [targetChannels] buffers are reused across blocks.
  @pragma('vm:prefer-inline')
  void deinterleaveFloatsFrom(
    Float32List interleaved,
    List<Float32List> targetChannels, {
    int? vectorSize,
  }) {
    final size = vectorSize ?? this.vectorSize;
    if (numChannels <= 0 || size <= 0 || targetChannels.isEmpty) return;

    if (numChannels == 1) {
      targetChannels[0].setRange(0, size, interleaved);
      return;
    }

    int start = 0;
    final simdSize = size <= this.vectorSize ? (size & ~3) : 0;
    if (SIMD.isSupported && simdSize > 0) {
      final interleaved4 = _targetView(interleaved);
      if (interleaved4 != null) {
        if (numChannels == 2) {
          final left4 = _channelView(0, targetChannels[0]);
          final right4 = _channelView(1, targetChannels[1]);
          if (left4 != null && right4 != null) {
            SIMD.deinterleaveStereoFloats(
              interleaved4,
              left4,
              right4,
              simdSize,
            );
            start = simdSize;
          }
        } else if (numChannels == 4) {
          final c0 = _channelView(0, targetChannels[0]);
          final c1 = _channelView(1, targetChannels[1]);
          final c2 = _channelView(2, targetChannels[2]);
          final c3 = _channelView(3, targetChannels[3]);
          if (c0 != null && c1 != null && c2 != null && c3 != null) {
            SIMD.deinterleaveQuadFloats(
              interleaved4,
              c0,
              c1,
              c2,
              c3,
              simdSize,
            );
            start = simdSize;
          }
        }
      }
    }

    if (start < size) {
      _deinterleaveFloatsScalar(
        interleaved,
        targetChannels,
        numChannels,
        start,
        size,
      );
    }
  }

  /// Interleaves [channels] into [floatBuffer] and returns [floatByteView].
  ///
  /// Zero heap allocations occur in steady state.
  @pragma('vm:prefer-inline')
  Uint8List interleaveFloat32Bytes(List<Float32List> channels) {
    interleaveFloatsTo(channels, floatBuffer);
    return floatByteView;
  }

  /// Interleaves [channels] into [pcm16Buffer] and returns [pcm16ByteView].
  ///
  /// Zero heap allocations occur in steady state.
  @pragma('vm:prefer-inline')
  Uint8List interleavePcm16Bytes(List<Float32List> channels) {
    interleavePcm16To(channels, pcm16Buffer);
    return pcm16ByteView;
  }
}
