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
}
