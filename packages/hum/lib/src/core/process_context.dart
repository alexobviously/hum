/// Per-block runtime audio configuration passed to [AudioProcessor.process].
class const ProcessContext._({
  required final int sampleRate,
  required final int vectorSize,

  /// Monotonic topology version managed internally by [AudioEngine].
  ///
  /// Incremented whenever the compiled execution schedule or buffer slot
  /// assignments change (`>= 1` inside [AudioEngine] and compiled
  /// [AudioPipeline]s; `0` for standalone [ProcessContext] instances).
  /// Processors that cache buffer views (such as SIMD nodes) can compare
  /// `context.epoch` in O(1) to invalidate stale views.
  ///
  /// Callers should not set this manually — it is hidden from the public
  /// constructor and updated automatically by the engine via [withEpoch].
  required final int epoch,
}) {
  this
    : assert(
        vectorSize > 0 && vectorSize % 4 == 0,
        'vectorSize must be a positive multiple of 4',
      );

  /// Creates a [ProcessContext] with the given [sampleRate] and [vectorSize].
  const ProcessContext({
    required int sampleRate,
    required int vectorSize,
  }) : this._(
         sampleRate: sampleRate,
         vectorSize: vectorSize,
         epoch: 0,
       );

  /// Returns a copy of this context with an updated topology [epoch].
  ///
  /// Intended for [AudioEngine] and [AudioPipeline] when buffer slot
  /// assignments are established or updated.
  ProcessContext withEpoch(int epoch) => ProcessContext._(
    sampleRate: sampleRate,
    vectorSize: vectorSize,
    epoch: epoch,
  );
}
