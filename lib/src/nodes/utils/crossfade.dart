import 'dart:typed_data';

import 'package:hum/hum.dart';

/// The blending law applied by [Crossfade].
enum CrossfadeMode {
  /// Equal-power (quarter-sine/cosine) crossfading.
  ///
  /// Maintains constant perceived acoustic energy (+0 dB at center mix 0.0)
  /// without the -3 dB volume dip characteristic of linear crossfading.
  /// Recommended for audio signals.
  equalPower,

  /// Linear crossfading: `out = a * (1 - norm) + b * norm`.
  ///
  /// Recommended for control signals, envelopes, and LFOs.
  linear,
}

typedef CrossfadeParams = ({double? mix, CrossfadeMode mode});

/// An [AudioNode] that blends between two signals or multi-channel buses [a] and [b]
/// according to a bipolar [mix] parameter (`-1.0` = 100% [a], `0.0` = 50/50 center, `+1.0` = 100% [b]).
///
/// Supports mono, stereo, and multichannel inputs, with both block-constant
/// values and audio-rate signal modulation for [mix].
class Crossfade implements AudioNode<CrossfadeProcessor> {
  final List<Outlet> a;
  final List<Outlet> b;

  /// Mix position from `-1.0` (all [a]) to `+1.0` (all [b]). `0.0` is centre.
  /// Defaults to `0.0`.
  final ControlParam<double> mix;

  /// Blending curve ([CrossfadeMode.equalPower] or [CrossfadeMode.linear]).
  final CrossfadeMode mode;

  Crossfade({
    required this.a,
    required this.b,
    this.mix = const .value(0.0),
    this.mode = .equalPower,
  }) : assert(
         a.length == b.length,
         'Channels for inputs a and b must match in length (${a.length} != ${b.length})',
       );

  /// Convenience factory for mono signals.
  factory mono({
    required Outlet a,
    required Outlet b,
    ControlParam<double> mix = const .value(0.0),
    CrossfadeMode mode = .equalPower,
  }) => Crossfade(a: [a], b: [b], mix: mix, mode: mode);

  /// Convenience factory for stereo signals.
  factory stereo({
    required Outlet aLeft,
    required Outlet aRight,
    required Outlet bLeft,
    required Outlet bRight,
    ControlParam<double> mix = const .value(0.0),
    CrossfadeMode mode = .equalPower,
  }) => Crossfade(
    a: [aLeft, aRight],
    b: [bLeft, bRight],
    mix: mix,
    mode: mode,
  );

  int get numChannels => a.length;

  static const mixInlet = 0;
  static const audioInletOffset = 1;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: mixInlet, source: mix.outletOrNull),
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
    mix: mix.valueOrNull,
    mode: mode,
  );

  @override
  CrossfadeParams get params => (mix: mix.valueOrNull, mode: mode);
}

class CrossfadeProcessor implements AudioProcessor {
  final int numChannels;
  double? mix;
  CrossfadeMode mode;

  CrossfadeProcessor({
    required this.numChannels,
    required this.mix,
    required this.mode,
  });

  @override
  void update(Object params) {
    params = params as CrossfadeParams;
    mix = params.mix;
    mode = params.mode;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final mix = this.mix;
    final audioOffset = inputs.length > numChannels * 2
        ? Crossfade.audioInletOffset
        : 0;

    if (mix != null) {
      // Constant mix over the entire block
      final (gainA, gainB) = switch (mode) {
        .equalPower => equalPowerGains(mix),
        .linear => linearGains(mix),
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
      // Audio-rate signal modulation for mix
      final mixBuf = inputs[Crossfade.mixInlet];

      switch (mode) {
        case .equalPower:
          for (int c = 0; c < numChannels; c++) {
            final inA = inputs[audioOffset + c];
            final inB = inputs[audioOffset + numChannels + c];
            final out = outputs[c];

            for (int i = 0; i < length; i++) {
              final (gainA, gainB) = equalPowerGains(mixBuf[i]);
              out[i] = inA[i] * gainA + inB[i] * gainB;
            }
          }

        case .linear:
          for (int c = 0; c < numChannels; c++) {
            final inA = inputs[audioOffset + c];
            final inB = inputs[audioOffset + numChannels + c];
            final out = outputs[c];

            for (int i = 0; i < length; i++) {
              final (gainA, gainB) = linearGains(mixBuf[i]);
              out[i] = inA[i] * gainA + inB[i] * gainB;
            }
          }
      }
    }
  }
}
