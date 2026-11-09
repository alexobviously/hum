import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef ClampParams = ({double? min, double? max});

/// An [AudioNode] that clamps or clips incoming audio [channels] to specified bounds.
///
/// Supports:
/// - **Two-sided clamp** (`min != null && max != null`): Standard hard clipping / bounding.
/// - **Ceiling-only** (`min == null && max != null`): Peak ceiling / positive peak limiter.
/// - **Floor-only** (`min != null && max == null`): Half-wave rectifier / diode floor.
/// - **Dynamic audio-rate bounds**: [min] and [max] can be modulated via [ControlParam.signal].
class const Clamp({
  required final List<Outlet> channels,
  final ControlParam<double>? min,
  final ControlParam<double>? max,
}) extends AudioNode<ClampProcessor> {
  factory mono(
    Outlet input, {
    ControlParam<double>? min,
    ControlParam<double>? max,
  }) => Clamp(channels: [input], min: min, max: max);

  factory stereo(
    Outlet leftInput,
    Outlet rightInput, {
    ControlParam<double>? min,
    ControlParam<double>? max,
  }) => Clamp(channels: [leftInput, rightInput], min: min, max: max);

  /// Symmetrical hard clipping to `[-threshold, threshold]` (defaults to `[-1.0, 1.0]`).
  factory bipolar(Outlet input, {double threshold = 1.0}) => Clamp.mono(
    input,
    min: .value(-threshold.abs()),
    max: .value(threshold.abs()),
  );

  /// Unipolar bounding to `[0.0, 1.0]` (standard for CV, envelopes, and control signals).
  factory unipolar(Outlet input) => Clamp.mono(
    input,
    min: const .value(0.0),
    max: const .value(1.0),
  );

  static const minInlet = 0;
  static const maxInlet = 1;
  static const audioInletOffset = 2;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: minInlet, source: min?.outletOrNull),
    Inlet(node: this, index: maxInlet, source: max?.outletOrNull),
    for (int i = 0; i < channels.length; i++)
      Inlet(node: this, index: audioInletOffset + i, source: channels[i]),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(channels.length, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;

  @override
  List<Object?> get fixedProps => [
    min?.isSignal,
    max?.isSignal,
  ];

  @override
  List<Object?> get dynamicProps => [min, max];

  @override
  ClampProcessor createProcessor() => ClampProcessor(
    numChannels: channels.length,
    min: min?.valueOrNull,
    max: max?.valueOrNull,
    isMinSignal: min?.outletOrNull != null,
    isMaxSignal: max?.outletOrNull != null,
  );

  @override
  ClampParams get params => (min: min?.valueOrNull, max: max?.valueOrNull);
}

class ClampProcessor({
  required final int numChannels,
  var double? min,
  var double? max,
  final bool isMinSignal = false,
  final bool isMaxSignal = false,
}) implements AudioProcessor {
  @override
  void update(Object params) {
    params = params as ClampParams;
    min = params.min;
    max = params.max;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final minBuf = isMinSignal ? inputs[Clamp.minInlet] : null;
    final maxBuf = isMaxSignal ? inputs[Clamp.maxInlet] : null;
    final staticMin = min;
    final staticMax = max;

    // Fast path: static scalar bounds
    if (minBuf == null && maxBuf == null) {
      if (staticMin == null && staticMax == null) {
        // Full passthrough
        for (int c = 0; c < numChannels; c++) {
          outputs[c].setRange(0, length, inputs[Clamp.audioInletOffset + c]);
        }
        return;
      }

      final lo = staticMin ?? -double.infinity;
      final hi = staticMax ?? double.infinity;

      for (int c = 0; c < numChannels; c++) {
        final inBuf = inputs[Clamp.audioInletOffset + c];
        final outBuf = outputs[c];
        for (int i = 0; i < length; i++) {
          outBuf[i] = inBuf[i].fastClamp(lo, hi);
        }
      }
      return;
    }

    // Modulated audio-rate bounds path
    final fallbackMin = staticMin ?? -double.infinity;
    final fallbackMax = staticMax ?? double.infinity;

    for (int c = 0; c < numChannels; c++) {
      final inBuf = inputs[Clamp.audioInletOffset + c];
      final outBuf = outputs[c];

      for (int i = 0; i < length; i++) {
        final lo = minBuf != null ? minBuf[i] : fallbackMin;
        final hi = maxBuf != null ? maxBuf[i] : fallbackMax;
        outBuf[i] = inBuf[i].fastClamp(lo, hi);
      }
    }
  }
}

/// Inlined scalar clamp function for unboxed `double` values.
///
/// Compiles directly to native floating-point min/max instructions with zero
/// heap allocations or boxing overhead.
@pragma('vm:prefer-inline')
double clampDouble(double value, double min, double max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

/// Zero-allocation clamp extension on [double].
///
/// Replaces `num.clamp(min, max)` in audio rendering loops to avoid polymorphic
/// dispatch and heap-allocated `_Double` boxing.
extension FastClampDouble on double {
  /// Clamps this [double] between [min] and [max] with zero heap allocation.
  @pragma('vm:prefer-inline')
  double fastClamp(double min, double max) {
    if (this < min) return min;
    if (this > max) return max;
    return this;
  }
}

/// Zero-allocation clamp extension on [int].
extension FastClampInt on int {
  /// Clamps this [int] between [min] and [max] with zero heap allocation.
  @pragma('vm:prefer-inline')
  int fastClamp(int min, int max) {
    if (this < min) return min;
    if (this > max) return max;
    return this;
  }
}

extension OutletClampExtension on Outlet {
  /// Clamps this signal between [min] and [max].
  Outlet clamp({double? min, double? max}) => Clamp.mono(
    this,
    min: min != null ? .value(min) : null,
    max: max != null ? .value(max) : null,
  ).outlet;

  /// Symmetrically hard-clips this signal to `[-threshold, threshold]` (defaults to 1.0).
  Outlet clip([double threshold = 1.0]) =>
      Clamp.bipolar(this, threshold: threshold).outlet;
}
