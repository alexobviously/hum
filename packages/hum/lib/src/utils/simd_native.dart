import 'dart:typed_data';

/// A platform-adaptive vector view over a [Float32List] audio buffer.
///
/// On the Dart Native VM, this aliases [Float32x4List] (128-bit NEON / SSE).
/// On Web (Wasm / JS), this aliases [Float32List] directly.
typedef SimdList = Float32x4List;

/// Hardware-accelerated 128-bit SIMD vector kernels for the Dart Native VM.
abstract final class SIMD {
  /// Whether hardware 128-bit SIMD acceleration is active on this platform.
  static const bool isSupported = true;

  /// Whether [buffer] satisfies the 16-byte offset alignment required by [view].
  @pragma('vm:prefer-inline')
  static bool isAligned(Float32List buffer) => (buffer.offsetInBytes & 15) == 0;

  /// Creates a 128-bit aligned [SimdList] view over [buffer] for [vectorSize] samples.
  @pragma('vm:prefer-inline')
  static SimdList view(Float32List buffer, int vectorSize) =>
      buffer.buffer.asFloat32x4List(buffer.offsetInBytes, vectorSize >> 2);

  /// Computes `out[i] = a[i] + b[i]` for [vectorSize] samples.
  @pragma('vm:prefer-inline')
  static void add(
    SimdList out,
    SimdList a,
    SimdList b,
    int vectorSize,
  ) {
    final len = vectorSize >> 2;
    for (int i = 0; i < len; i++) {
      out[i] = a[i] + b[i];
    }
  }

  /// Computes `out[i] += a[i]` in-place for [vectorSize] samples.
  @pragma('vm:prefer-inline')
  static void accumulate(
    SimdList out,
    SimdList a,
    int vectorSize,
  ) {
    final len = vectorSize >> 2;
    for (int i = 0; i < len; i++) {
      out[i] = out[i] + a[i];
    }
  }

  /// Computes `out[i] = a[i] * scalar` for [vectorSize] samples.
  @pragma('vm:prefer-inline')
  static void scale(
    SimdList out,
    SimdList a,
    double scalar,
    int vectorSize,
  ) {
    final scalar4 = Float32x4.splat(scalar);
    final len = vectorSize >> 2;
    for (int i = 0; i < len; i++) {
      out[i] = a[i] * scalar4;
    }
  }

  /// Computes `out[i] = a[i] * b[i]` for [vectorSize] samples.
  @pragma('vm:prefer-inline')
  static void multiply(
    SimdList out,
    SimdList a,
    SimdList b,
    int vectorSize,
  ) {
    final len = vectorSize >> 2;
    for (int i = 0; i < len; i++) {
      out[i] = a[i] * b[i];
    }
  }

  /// Computes `out[i] = a[i] * gainA + b[i] * gainB` for [vectorSize] samples.
  @pragma('vm:prefer-inline')
  static void linearBlend(
    SimdList out,
    SimdList a,
    double gainA,
    SimdList b,
    double gainB,
    int vectorSize,
  ) {
    final gainA4 = Float32x4.splat(gainA);
    final gainB4 = Float32x4.splat(gainB);
    final len = vectorSize >> 2;
    for (int i = 0; i < len; i++) {
      out[i] = (a[i] * gainA4) + (b[i] * gainB4);
    }
  }

  /// Interleaves stereo [left] and [right] channels into [out] for [vectorSize] frames.
  ///
  /// [out] must contain at least `vectorSize * 2` float samples.
  @pragma('vm:prefer-inline')
  static void interleaveStereoFloats(
    SimdList out,
    SimdList left,
    SimdList right,
    int vectorSize,
  ) {
    final len = vectorSize >> 2;
    for (int i = 0; i < len; i++) {
      final l = left[i];
      final r = right[i];
      final outIdx = i << 1;
      out[outIdx] = Float32x4(l.x, r.x, l.y, r.y);
      out[outIdx + 1] = Float32x4(l.z, r.z, l.w, r.w);
    }
  }

  /// Interleaves 4 channels ([c0], [c1], [c2], [c3]) into [out] for [vectorSize] frames.
  ///
  /// [out] must contain at least `vectorSize * 4` float samples.
  @pragma('vm:prefer-inline')
  static void interleaveQuadFloats(
    SimdList out,
    SimdList c0,
    SimdList c1,
    SimdList c2,
    SimdList c3,
    int vectorSize,
  ) {
    final len = vectorSize >> 2;
    for (int i = 0; i < len; i++) {
      final v0 = c0[i];
      final v1 = c1[i];
      final v2 = c2[i];
      final v3 = c3[i];
      final outIdx = i << 2;
      out[outIdx] = Float32x4(v0.x, v1.x, v2.x, v3.x);
      out[outIdx + 1] = Float32x4(v0.y, v1.y, v2.y, v3.y);
      out[outIdx + 2] = Float32x4(v0.z, v1.z, v2.z, v3.z);
      out[outIdx + 3] = Float32x4(v0.w, v1.w, v2.w, v3.w);
    }
  }

  /// De-interleaves stereo [interleaved] audio into [left] and [right] for [vectorSize] frames.
  @pragma('vm:prefer-inline')
  static void deinterleaveStereoFloats(
    SimdList interleaved,
    SimdList left,
    SimdList right,
    int vectorSize,
  ) {
    final len = vectorSize >> 2;
    for (int i = 0; i < len; i++) {
      final inIdx = i << 1;
      final v0 = interleaved[inIdx];
      final v1 = interleaved[inIdx + 1];
      left[i] = Float32x4(v0.x, v0.z, v1.x, v1.z);
      right[i] = Float32x4(v0.y, v0.w, v1.y, v1.w);
    }
  }

  /// De-interleaves 4-channel [interleaved] audio into [c0], [c1], [c2], [c3] for [vectorSize] frames.
  @pragma('vm:prefer-inline')
  static void deinterleaveQuadFloats(
    SimdList interleaved,
    SimdList c0,
    SimdList c1,
    SimdList c2,
    SimdList c3,
    int vectorSize,
  ) {
    final len = vectorSize >> 2;
    for (int i = 0; i < len; i++) {
      final inIdx = i << 2;
      final v0 = interleaved[inIdx];
      final v1 = interleaved[inIdx + 1];
      final v2 = interleaved[inIdx + 2];
      final v3 = interleaved[inIdx + 3];
      c0[i] = Float32x4(v0.x, v1.x, v2.x, v3.x);
      c1[i] = Float32x4(v0.y, v1.y, v2.y, v3.y);
      c2[i] = Float32x4(v0.z, v1.z, v2.z, v3.z);
      c3[i] = Float32x4(v0.w, v1.w, v2.w, v3.w);
    }
  }

  // Adding 1.5 * 2^23 (0x4B400000) shifts the float32 exponent so the ULP is
  // 1.0, performing IEEE-754 round-to-nearest-even in a single vector add and
  // placing the signed 16-bit two's-complement integer in the low 16 bits.
  static const double _pcm16MagicBias = 12582912.0;

  /// Converts mono float audio in [channel] to clamped 16-bit integer PCM in [out] for [vectorSize] samples.
  @pragma('vm:prefer-inline')
  static void interleaveMonoPcm16(
    Int16List out,
    SimdList channel,
    int vectorSize,
  ) {
    final min4 = Float32x4.splat(-1.0);
    final max4 = Float32x4.splat(1.0);
    final scale4 = Float32x4.splat(32767.0);
    final magic4 = Float32x4.splat(_pcm16MagicBias);
    final len = vectorSize >> 2;
    int writeIdx = 0;
    for (int i = 0; i < len; i++) {
      final v = channel[i].clamp(min4, max4) * scale4 + magic4;
      final vi = Int32x4.fromFloat32x4Bits(v);
      out[writeIdx++] = vi.x;
      out[writeIdx++] = vi.y;
      out[writeIdx++] = vi.z;
      out[writeIdx++] = vi.w;
    }
  }

  /// Interleaves and converts stereo [left] and [right] float audio to clamped 16-bit integer PCM in [out].
  @pragma('vm:prefer-inline')
  static void interleaveStereoPcm16(
    Int16List out,
    SimdList left,
    SimdList right,
    int vectorSize,
  ) {
    final min4 = Float32x4.splat(-1.0);
    final max4 = Float32x4.splat(1.0);
    final scale4 = Float32x4.splat(32767.0);
    final magic4 = Float32x4.splat(_pcm16MagicBias);
    final len = vectorSize >> 2;
    int writeIdx = 0;
    for (int i = 0; i < len; i++) {
      final l = left[i].clamp(min4, max4) * scale4 + magic4;
      final r = right[i].clamp(min4, max4) * scale4 + magic4;
      final li = Int32x4.fromFloat32x4Bits(l);
      final ri = Int32x4.fromFloat32x4Bits(r);
      out[writeIdx++] = li.x;
      out[writeIdx++] = ri.x;
      out[writeIdx++] = li.y;
      out[writeIdx++] = ri.y;
      out[writeIdx++] = li.z;
      out[writeIdx++] = ri.z;
      out[writeIdx++] = li.w;
      out[writeIdx++] = ri.w;
    }
  }

  /// Interleaves and converts one channel of float audio in [channel] to
  /// clamped 16-bit integer PCM at [channelIndex] with stride [numChannels] in [out].
  @pragma('vm:prefer-inline')
  static void interleaveChannelPcm16(
    Int16List out,
    SimdList channel,
    int channelIndex,
    int numChannels,
    int vectorSize,
  ) {
    final min4 = Float32x4.splat(-1.0);
    final max4 = Float32x4.splat(1.0);
    final scale4 = Float32x4.splat(32767.0);
    final magic4 = Float32x4.splat(_pcm16MagicBias);
    final len = vectorSize >> 2;
    final stride2 = numChannels << 1;
    final stride3 = stride2 + numChannels;
    final stride4 = numChannels << 2;
    int writeIdx = channelIndex;
    for (int i = 0; i < len; i++) {
      final v = channel[i].clamp(min4, max4) * scale4 + magic4;
      final vi = Int32x4.fromFloat32x4Bits(v);
      out[writeIdx] = vi.x;
      out[writeIdx + numChannels] = vi.y;
      out[writeIdx + stride2] = vi.z;
      out[writeIdx + stride3] = vi.w;
      writeIdx += stride4;
    }
  }
}
