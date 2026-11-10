import 'dart:typed_data';

/// Helpers for common SIMD operations.
abstract final class SIMD {
  @pragma('vm:prefer-inline')
  static void add(
    Float32x4List out,
    Float32x4List a,
    Float32x4List b,
    int len,
  ) {
    for (int i = 0; i < len; i++) {
      out[i] = a[i] + b[i];
    }
  }

  @pragma('vm:prefer-inline')
  static void accumulate(
    Float32x4List out,
    Float32x4List a,
    int len,
  ) {
    for (int i = 0; i < len; i++) {
      out[i] = out[i] + a[i];
    }
  }

  @pragma('vm:prefer-inline')
  static void scale(
    Float32x4List out,
    Float32x4List a,
    Float32x4 scalar,
    int len,
  ) {
    for (int i = 0; i < len; i++) {
      out[i] = a[i] * scalar;
    }
  }

  @pragma('vm:prefer-inline')
  static void multiply(
    Float32x4List out,
    Float32x4List a,
    Float32x4List b,
    int len,
  ) {
    for (int i = 0; i < len; i++) {
      out[i] = a[i] * b[i];
    }
  }

  @pragma('vm:prefer-inline')
  static void linearBlend(
    Float32x4List out,
    Float32x4List a,
    Float32x4 gainA,
    Float32x4List b,
    Float32x4 gainB,
    int len,
  ) {
    for (int i = 0; i < len; i++) {
      out[i] = (a[i] * gainA) + (b[i] * gainB);
    }
  }
}
