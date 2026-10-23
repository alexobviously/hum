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

typedef CrossfadeParams = ({double? position, CrossfadeMode mode});

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

  Crossfade({
    required this.a,
    required this.b,
    this.position = const .value(0.0),
    this.mode = .equalPower,
  }) : assert(
         a.length == b.length,
         'Channels for inputs a and b must match in length (${a.length} != ${b.length})',
       );

  /// Convenience factory for mono signals.
  factory mono({
    required Outlet a,
    required Outlet b,
    ControlParam<double> position = const .value(0.0),
    CrossfadeMode mode = .equalPower,
  }) => Crossfade(a: [a], b: [b], position: position, mode: mode);

  /// Convenience factory for stereo signals.
  factory stereo({
    required Outlet aLeft,
    required Outlet aRight,
    required Outlet bLeft,
    required Outlet bRight,
    ControlParam<double> position = const .value(0.0),
    CrossfadeMode mode = .equalPower,
  }) => Crossfade(
    a: [aLeft, aRight],
    b: [bLeft, bRight],
    position: position,
    mode: mode,
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
  );

  @override
  CrossfadeParams get params => (position: position.valueOrNull, mode: mode);

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
  ];

  @override
  bool canUpdate(covariant Crossfade newNode) =>
      super.canUpdate(newNode) && numChannels == newNode.numChannels;
}

class CrossfadeProcessor implements AudioProcessor {
  final int numChannels;
  double? position;
  CrossfadeMode mode;

  CrossfadeProcessor({
    required this.numChannels,
    required this.position,
    required this.mode,
  });

  @override
  void update(Object params) {
    params = params as CrossfadeParams;
    position = params.position;
    mode = params.mode;
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
      // Constant position over the entire block
      final (gainA, gainB) = switch (mode) {
        .equalPower => equalPowerGains(position),
        .linear => linearGains(position),
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
