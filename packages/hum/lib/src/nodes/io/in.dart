import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Reads live audio from the host's active [AudioInput] channels into the graph.
///
/// Mirrors [Out] on the input side. Pass 0-based hardware channel indices via
/// [channels] (or use [In.mono] / [In.stereo]). If no [AudioInput] is attached
/// or a requested channel index exceeds the active input channel count, that
/// outlet produces silence.
class In({
  required final List<int> channels,
}) extends AudioNode<InProcessor> {
  /// Reads a single hardware input channel (defaults to channel `0`).
  new mono([int channel = 0]) : this(channels: [channel]);

  /// Reads a stereo pair of hardware input channels (defaults to `[0, 1]`).
  new stereo([int left = 0, int right = 1]) : this(channels: [left, right]);

  @override
  List<Inlet> get inlets => const [];

  @override
  List<Outlet> get outlets => List.generate(
    channels.length,
    (i) => Outlet(node: this, index: i),
  );

  /// The first output channel (convenience getter for mono sources).
  Outlet get outlet => outlets.first;

  /// The left channel outlet (convenience getter for stereo sources).
  Outlet get left => outlets[0];

  /// The right channel outlet (convenience getter for stereo sources).
  Outlet get right => outlets[1];

  @override
  InProcessor createProcessor() => InProcessor(channels: channels);

  @override
  Object get params => ();

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeParamError(param: 'channels', error: 'must not be empty'),
    for (final ch in channels)
      if (ch < 0)
        AudioNodeParamError(
          param: 'channels',
          error: 'channel index must be non-negative (got $ch)',
        ),
  ];

  @override
  List<Object?> get fixedProps => [channels];

  @override
  List<Object?> get dynamicProps => const [];
}

/// The runtime processor for [In].
class InProcessor({
  required final List<int> channels,
}) implements InputAwareProcessor {
  List<Float32List> _engineInputs = const [];

  @override
  void bindInputs(List<Float32List> engineInputs) {
    _engineInputs = engineInputs;
  }

  @override
  void update(Object params) {}

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final vs = context.vectorSize;
    final engineInputs = _engineInputs;

    for (int i = 0; i < channels.length; i++) {
      final ch = channels[i];
      if (ch >= 0 && ch < engineInputs.length) {
        outputs[i].setRange(0, vs, engineInputs[ch]);
      } else {
        outputs[i].fillRange(0, vs, 0.0);
      }
    }
  }
}
