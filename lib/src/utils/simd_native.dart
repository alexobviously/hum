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
}
