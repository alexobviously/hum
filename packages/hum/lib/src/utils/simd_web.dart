import 'dart:typed_data';

/// A platform-adaptive vector view over a [Float32List] audio buffer.
///
/// On Web (Wasm and JS), `dart:typed_data`'s [Float32x4List] uses the software
/// `NaiveFloat32x4List` polyfill which boxes a heap object on every element access.
/// Aliasing [Float32List] directly avoids all heap allocations and allows the
/// browser's Wasm JIT to auto-vectorize loops.
typedef SimdList = Float32List;

/// Unboxed scalar vector kernels for Web (Wasm & JS).
abstract final class SIMD {
  /// Whether hardware 128-bit `Float32x4List` SIMD is active on this platform.
  static const bool isSupported = false;

  /// Always returns `true` on Web since [SimdList] is a scalar [Float32List].
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static bool isAligned(Float32List buffer) => true;

  /// Returns [buffer] directly with zero allocation on Web.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static SimdList view(Float32List buffer, int vectorSize) => buffer;

  /// Computes `out[i] = a[i] + b[i]` for [vectorSize] samples.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void add(
    SimdList out,
    SimdList a,
    SimdList b,
    int vectorSize,
  ) {
    for (int i = 0; i < vectorSize; i++) {
      out[i] = a[i] + b[i];
    }
  }

  /// Computes `out[i] += a[i]` in-place for [vectorSize] samples.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void accumulate(
    SimdList out,
    SimdList a,
    int vectorSize,
  ) {
    for (int i = 0; i < vectorSize; i++) {
      out[i] = out[i] + a[i];
    }
  }

  /// Computes `out[i] = a[i] * scalar` for [vectorSize] samples.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void scale(
    SimdList out,
    SimdList a,
    double scalar,
    int vectorSize,
  ) {
    for (int i = 0; i < vectorSize; i++) {
      out[i] = a[i] * scalar;
    }
  }

  /// Computes `out[i] = a[i] * b[i]` for [vectorSize] samples.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void multiply(
    SimdList out,
    SimdList a,
    SimdList b,
    int vectorSize,
  ) {
    for (int i = 0; i < vectorSize; i++) {
      out[i] = a[i] * b[i];
    }
  }

  /// Computes `out[i] = a[i] * gainA + b[i] * gainB` for [vectorSize] samples.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void linearBlend(
    SimdList out,
    SimdList a,
    double gainA,
    SimdList b,
    double gainB,
    int vectorSize,
  ) {
    for (int i = 0; i < vectorSize; i++) {
      out[i] = (a[i] * gainA) + (b[i] * gainB);
    }
  }

  /// Interleaves stereo [left] and [right] channels into [out] for [vectorSize] frames.
  ///
  /// [out] must contain at least `vectorSize * 2` float samples.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void interleaveStereoFloats(
    SimdList out,
    SimdList left,
    SimdList right,
    int vectorSize,
  ) {
    int writeIdx = 0;
    for (int i = 0; i < vectorSize; i++) {
      out[writeIdx++] = left[i];
      out[writeIdx++] = right[i];
    }
  }

  /// Interleaves 4 channels ([c0], [c1], [c2], [c3]) into [out] for [vectorSize] frames.
  ///
  /// [out] must contain at least `vectorSize * 4` float samples.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void interleaveQuadFloats(
    SimdList out,
    SimdList c0,
    SimdList c1,
    SimdList c2,
    SimdList c3,
    int vectorSize,
  ) {
    int writeIdx = 0;
    for (int i = 0; i < vectorSize; i++) {
      out[writeIdx++] = c0[i];
      out[writeIdx++] = c1[i];
      out[writeIdx++] = c2[i];
      out[writeIdx++] = c3[i];
    }
  }

  /// De-interleaves stereo [interleaved] audio into [left] and [right] for [vectorSize] frames.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void deinterleaveStereoFloats(
    SimdList interleaved,
    SimdList left,
    SimdList right,
    int vectorSize,
  ) {
    int readIdx = 0;
    for (int i = 0; i < vectorSize; i++) {
      left[i] = interleaved[readIdx++];
      right[i] = interleaved[readIdx++];
    }
  }

  /// De-interleaves 4-channel [interleaved] audio into [c0], [c1], [c2], [c3] for [vectorSize] frames.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void deinterleaveQuadFloats(
    SimdList interleaved,
    SimdList c0,
    SimdList c1,
    SimdList c2,
    SimdList c3,
    int vectorSize,
  ) {
    int readIdx = 0;
    for (int i = 0; i < vectorSize; i++) {
      c0[i] = interleaved[readIdx++];
      c1[i] = interleaved[readIdx++];
      c2[i] = interleaved[readIdx++];
      c3[i] = interleaved[readIdx++];
    }
  }

  /// Converts mono float audio in [channel] to clamped 16-bit integer PCM in [out] for [vectorSize] samples.
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void interleaveMonoPcm16(
    Int16List out,
    SimdList channel,
    int vectorSize,
  ) {
    for (int i = 0; i < vectorSize; i++) {
      double sample = channel[i];
      if (sample < -1.0) {
        sample = -1.0;
      } else if (sample > 1.0) {
        sample = 1.0;
      }
      out[i] = (sample * 32767.0).round();
    }
  }

  /// Interleaves and converts stereo [left] and [right] float audio to clamped 16-bit integer PCM in [out].
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void interleaveStereoPcm16(
    Int16List out,
    SimdList left,
    SimdList right,
    int vectorSize,
  ) {
    int writeIdx = 0;
    for (int i = 0; i < vectorSize; i++) {
      double sampleL = left[i];
      if (sampleL < -1.0) {
        sampleL = -1.0;
      } else if (sampleL > 1.0) {
        sampleL = 1.0;
      }
      double sampleR = right[i];
      if (sampleR < -1.0) {
        sampleR = -1.0;
      } else if (sampleR > 1.0) {
        sampleR = 1.0;
      }
      out[writeIdx++] = (sampleL * 32767.0).round();
      out[writeIdx++] = (sampleR * 32767.0).round();
    }
  }

  /// Interleaves and converts one channel of float audio in [channel] to
  /// clamped 16-bit integer PCM at [channelIndex] with stride [numChannels] in [out].
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:tryInline')
  static void interleaveChannelPcm16(
    Int16List out,
    SimdList channel,
    int channelIndex,
    int numChannels,
    int vectorSize,
  ) {
    int writeIdx = channelIndex;
    for (int i = 0; i < vectorSize; i++) {
      double sample = channel[i];
      if (sample < -1.0) {
        sample = -1.0;
      } else if (sample > 1.0) {
        sample = 1.0;
      }
      out[writeIdx] = (sample * 32767.0).round();
      writeIdx += numChannels;
    }
  }
}
