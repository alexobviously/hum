import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef SlewParams = ({double? rise, double? fall});
typedef Portamento = Slew;
typedef Lag = Slew;

// Sleewwwww deeeeem

/// A slew rate limiter / lag processor.
///
/// Limits the maximum rate of change (slope) of an input signal.
///
/// Slew rate is defined as the time in seconds required for the output to
/// traverse a 1.0 unit step change. A value of `0.0` disables rate limiting
/// (instantaneous passthrough).
///
/// Common uses:
/// - **Portamento / Glide**: Smoothly gliding pitch between musical notes.
/// - **CV Smoothing**: Smoothing stepped signals from [Sah] or sequencers.
/// - **Transient De-harshing**: Rounding off square waves or sharp clicks.
class Slew({
  required final List<Outlet> channels,
  final ControlParam<double> rise = const .value(0.0),
  final ControlParam<double> fall = const .value(0.0),
  final double? initialValue,
}) extends AudioNode<SlewProcessor> {
  static const riseInlet = 0;
  static const fallInlet = 1;
  static const audioInletOffset = 2;

  /// Creates a symmetric slew limiter where rise and fall times are identical.
  factory symmetric({
    required List<Outlet> channels,
    ControlParam<double> time = const .value(0.0),
    double? initialValue,
  }) => Slew(
    channels: channels,
    rise: time,
    fall: time,
    initialValue: initialValue,
  );

  /// Convenience factory for a mono signal with optional symmetric or asymmetric times.
  factory mono({
    required Outlet input,
    ControlParam<double> rise = const .value(0.0),
    ControlParam<double> fall = const .value(0.0),
    ControlParam<double>? time,
    double? initialValue,
  }) => Slew(
    channels: [input],
    rise: time ?? rise,
    fall: time ?? fall,
    initialValue: initialValue,
  );

  /// Convenience factory for stereo signals.
  factory stereo({
    required Outlet leftInput,
    required Outlet rightInput,
    ControlParam<double> rise = const .value(0.0),
    ControlParam<double> fall = const .value(0.0),
    ControlParam<double>? time,
    double? initialValue,
  }) => Slew(
    channels: [leftInput, rightInput],
    rise: time ?? rise,
    fall: time ?? fall,
    initialValue: initialValue,
  );

  /// Convenience factory configuring slew in exact sample counts for a given [sampleRate].
  factory samples({
    required List<Outlet> channels,
    required double riseSamples,
    required double fallSamples,
    required int sampleRate,
  }) => Slew(
    channels: channels,
    rise: .value(riseSamples / sampleRate),
    fall: .value(fallSamples / sampleRate),
  );

  int get numChannels => channels.length;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: riseInlet, source: rise.outletOrNull),
    Inlet(node: this, index: fallInlet, source: fall.outletOrNull),
    ...List.generate(
      numChannels,
      (i) =>
          Inlet(node: this, index: audioInletOffset + i, source: channels[i]),
    ),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(numChannels, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  List<Object?> get fixedProps => [initialValue];

  @override
  List<Object?> get dynamicProps => [rise, fall];

  @override
  SlewProcessor createProcessor() => SlewProcessor(
    numChannels: numChannels,
    rise: rise.valueOrNull,
    fall: fall.valueOrNull,
    initialValue: initialValue,
  );

  @override
  SlewParams get params => (rise: rise.valueOrNull, fall: fall.valueOrNull);
}

class SlewProcessor({
  required final int numChannels,
  var double? rise,
  var double? fall,
  final double? initialValue,
}) implements AudioProcessor {
  late final _lastSamples = Float32List(numChannels)
    ..fillRange(0, numChannels, initialValue ?? 0.0);

  @override
  void update(Object params) {
    params = params as SlewParams;
    rise = params.rise;
    fall = params.fall;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final sr = context.sampleRate.toDouble();
    final audioOffset = inputs.length > numChannels ? Slew.audioInletOffset : 0;

    final riseBuf = inputs.length > Slew.riseInlet
        ? inputs[Slew.riseInlet]
        : null;
    final fallBuf = inputs.length > Slew.fallInlet
        ? inputs[Slew.fallInlet]
        : null;

    final staticRise = rise;
    final staticFall = fall;
    final hasSignalRise = staticRise == null && riseBuf != null;
    final hasSignalFall = staticFall == null && fallBuf != null;

    if (!hasSignalRise && !hasSignalFall) {
      // Fast path: static scalar rates
      final maxRise = (staticRise != null && staticRise > 0.0)
          ? (1.0 / (staticRise * sr))
          : double.infinity;
      final maxFall = (staticFall != null && staticFall > 0.0)
          ? (1.0 / (staticFall * sr))
          : double.infinity;

      for (int c = 0; c < numChannels; c++) {
        final inBuf = inputs[audioOffset + c];
        final outBuf = outputs[c];
        var last = _lastSamples[c];

        for (int i = 0; i < length; i++) {
          final diff = inBuf[i] - last;
          last += diff.fastClamp(-maxFall, maxRise);
          outBuf[i] = last;
        }
        _lastSamples[c] = last;
      }
    } else {
      // Modulated path: audio-rate modulated rise and/or fall times

      // Precalculating these to optimise inner loop
      final double constMaxRise = (staticRise != null && staticRise > 0.0)
          ? (1.0 / (staticRise * sr))
          : .infinity;
      final double constMaxFall = (staticFall != null && staticFall > 0.0)
          ? (1.0 / (staticFall * sr))
          : .infinity;

      for (int c = 0; c < numChannels; c++) {
        final inBuf = inputs[audioOffset + c];
        final outBuf = outputs[c];
        var last = _lastSamples[c];

        for (int i = 0; i < length; i++) {
          final double maxRise = hasSignalRise
              ? (riseBuf[i] > 0.0 ? 1.0 / (riseBuf[i] * sr) : .infinity)
              : constMaxRise;
          final double maxFall = hasSignalFall
              ? (fallBuf[i] > 0.0 ? 1.0 / (fallBuf[i] * sr) : .infinity)
              : constMaxFall;

          final diff = inBuf[i] - last;
          last += diff.fastClamp(-maxFall, maxRise);
          outBuf[i] = last;
        }
        _lastSamples[c] = last;
      }
    }
  }
}

extension OutletSlewExtension on Outlet {
  /// Applies slew rate limiting (portamento / glide) to this outlet.
  Slew slew([double time = 0.05, double? initialValue]) =>
      Slew.mono(input: this, time: .value(time), initialValue: initialValue);

  /// Alias for [slew].
  Slew portamento([double time = 0.05, double? initialValue]) =>
      slew(time, initialValue);
}
