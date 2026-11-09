import 'dart:typed_data';

import 'package:hum/hum.dart';

/// The blending law applied by [Crossfade].
enum CrossfadeMode {
  /// Equal-power (quarter-sine/cosine) crossfading.
  ///
  /// Maintains constant perceived acoustic energy (+0 dB at center position 0.0)
  /// without the -3 dB volume dip characteristic of linear crossfading.
  /// Recommended for audio signals.
  equalPower,

  /// Linear crossfading: `out = a * (1 - norm) + b * norm`.
  ///
  /// Recommended for control signals, envelopes, and LFOs.
  linear,
}

typedef CrossfadeParams = ({
  double? position,
  CrossfadeMode mode,
  double interpTime,
});

/// An [AudioNode] that blends between two signals or multi-channel buses [a] and [b]
/// according to a bipolar [position] parameter (`-1.0` = 100% [a], `0.0` = 50/50 center, `+1.0` = 100% [b]).
///
/// Supports mono, stereo, and multichannel inputs, with both block-constant
/// values and audio-rate signal modulation for [position].
class Crossfade extends AudioNode<CrossfadeProcessor> {
  final List<Outlet> a;
  final List<Outlet> b;

  /// Bipolar blend position from `-1.0` (all [a]) to `+1.0` (all [b]). `0.0` is centre.
  /// Defaults to `0.0`.
  final ControlParam<double> position;

  /// Blending curve ([CrossfadeMode.equalPower] or [CrossfadeMode.linear]).
  final CrossfadeMode mode;

  /// Time in seconds to interpolate to new static [position] values.
  final double interpTime;

  Crossfade({
    required this.a,
    required this.b,
    this.position = const .value(0.0),
    this.mode = .equalPower,
    this.interpTime = 0.02,
  }) : assert(
         a.length == b.length,
         'Channels for inputs a and b must match in length (${a.length} != ${b.length})',
       ),
       assert(interpTime >= 0.0, 'interpTime must be non-negative');

  /// Convenience factory for mono signals.
  factory mono({
    required Outlet a,
    required Outlet b,
    ControlParam<double> position = const .value(0.0),
    CrossfadeMode mode = .equalPower,
    double interpTime = 0.02,
  }) => Crossfade(
    a: [a],
    b: [b],
    position: position,
    mode: mode,
    interpTime: interpTime,
  );

  /// Convenience factory for stereo signals.
  factory stereo({
    required Outlet aLeft,
    required Outlet aRight,
    required Outlet bLeft,
    required Outlet bRight,
    ControlParam<double> position = const .value(0.0),
    CrossfadeMode mode = .equalPower,
    double interpTime = 0.02,
  }) => Crossfade(
    a: [aLeft, aRight],
    b: [bLeft, bRight],
    position: position,
    mode: mode,
    interpTime: interpTime,
  );

  int get numChannels => a.length;

  static const positionInlet = 0;
  static const audioInletOffset = 1;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: positionInlet, source: position.outletOrNull),
    ...List.generate(
      numChannels,
      (i) => Inlet(node: this, index: audioInletOffset + i, source: a[i]),
    ),
    ...List.generate(
      numChannels,
      (i) => Inlet(
        node: this,
        index: audioInletOffset + numChannels + i,
        source: b[i],
      ),
    ),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(numChannels, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  CrossfadeProcessor createProcessor() => CrossfadeProcessor(
    numChannels: numChannels,
    position: position.valueOrNull,
    mode: mode,
    interpTime: interpTime,
  );

  @override
  CrossfadeParams get params => (
    position: position.valueOrNull,
    mode: mode,
    interpTime: interpTime,
  );

  @override
  List<AudioNodeError> get errors => [
    if (a.isEmpty)
      const AudioNodeParamError(param: 'a', error: 'must not be empty'),
    if (b.isEmpty)
      const AudioNodeParamError(param: 'b', error: 'must not be empty'),
    if (a.length != b.length)
      AudioNodeParamError(
        param: 'b',
        error: 'channel count (${b.length}) must match a (${a.length})',
      ),
    if (interpTime < 0)
      const AudioNodeParamError(
        param: 'interpTime',
        error: 'must be non-negative',
      ),
  ];

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [position, mode, interpTime];
}

class CrossfadeProcessor implements AudioProcessor {
  final int numChannels;
  double? position;
  CrossfadeMode mode;
  double interpTime;

  CrossfadeProcessor({
    required this.numChannels,
    required this.position,
    required this.mode,
    this.interpTime = 0.02,
  });

  // To prevent 'zipper' noises when adjusting position sharply
  late final SmoothedValue _posSmoother = SmoothedValue(position ?? 0.0);

  @override
  void update(Object params) {
    final p = params as CrossfadeParams;
    final oldPos = position;
    position = p.position;
    mode = p.mode;
    interpTime = p.interpTime;

    if (p.position != null) {
      if (oldPos == null || interpTime <= 0.0) {
        _posSmoother.snapTo(p.position!);
      } else {
        _posSmoother.setTarget(p.position!);
      }
    }
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final position = this.position;
    final audioOffset = inputs.length > numChannels * 2
        ? Crossfade.audioInletOffset
        : 0;

    if (position != null) {
      _posSmoother.configure(
        sampleRate: context.sampleRate.toDouble(),
        rampTime: interpTime,
      );

      if (_posSmoother.isSettled) {
        // Constant position over the entire block
        final (gainA, gainB) = switch (mode) {
          .equalPower => equalPowerGains(_posSmoother.current),
          .linear => linearGains(_posSmoother.current),
        };

        for (int c = 0; c < numChannels; c++) {
          final inA = inputs[audioOffset + c];
          final inB = inputs[audioOffset + numChannels + c];
          final out = outputs[c];

          for (int i = 0; i < length; i++) {
            out[i] = inA[i] * gainA + inB[i] * gainB;
          }
        }
      } else {
        // Interpolating position per frame across channels
        for (int i = 0; i < length; i++) {
          final pos = _posSmoother.next();
          final (gainA, gainB) = switch (mode) {
            .equalPower => equalPowerGains(pos),
            .linear => linearGains(pos),
          };

          for (int c = 0; c < numChannels; c++) {
            outputs[c][i] =
                inputs[audioOffset + c][i] * gainA +
                inputs[audioOffset + numChannels + c][i] * gainB;
          }
        }
      }
    } else {
      // Audio-rate signal modulation for position
      final posBuf = inputs[Crossfade.positionInlet];

      switch (mode) {
        case .equalPower:
          for (int c = 0; c < numChannels; c++) {
            final inA = inputs[audioOffset + c];
            final inB = inputs[audioOffset + numChannels + c];
            final out = outputs[c];

            for (int i = 0; i < length; i++) {
              final (gainA, gainB) = equalPowerGains(posBuf[i]);
              out[i] = inA[i] * gainA + inB[i] * gainB;
            }
          }

        case .linear:
          for (int c = 0; c < numChannels; c++) {
            final inA = inputs[audioOffset + c];
            final inB = inputs[audioOffset + numChannels + c];
            final out = outputs[c];

            for (int i = 0; i < length; i++) {
              final (gainA, gainB) = linearGains(posBuf[i]);
              out[i] = inA[i] * gainA + inB[i] * gainB;
            }
          }
      }
    }
  }
}
