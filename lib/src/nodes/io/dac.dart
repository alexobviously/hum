import 'dart:typed_data';

import 'package:hum/hum.dart';

/// A terminal audio node representing the Digital-to-Analog Converter (DAC / speaker).
///
/// Serves as the declarative endpoint of an audio graph. Upstream inlets connected to
/// [Dac] are automatically designated as the graph's output channels in [compileGraph].
class Dac({
  required final List<Outlet> channels,
}) extends AudioNode<DacProcessor> {
  /// Creates a single-channel mono DAC terminal node.
  Dac.mono(Outlet channel) : this(channels: [channel]);

  /// Creates a two-channel stereo DAC terminal node.
  Dac.stereo({required Outlet left, required Outlet right})
    : this(channels: [left, right]);

  @override
  List<Inlet> get inlets => List.generate(
    channels.length,
    (i) => Inlet(node: this, index: i, source: channels[i]),
  );

  @override
  List<Outlet> get outlets => const [];

  @override
  DacProcessor createProcessor() => const DacProcessor();

  @override
  Object get params => ();

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeParamError(param: 'channels', error: 'must not be empty'),
  ];

  @override
  bool canUpdate(covariant Dac newNode) =>
      super.canUpdate(newNode) && channels.length == newNode.channels.length;
}

/// The runtime processor for [Dac].
class const DacProcessor() implements AudioProcessor {
  @override
  void update(Object params) {}

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    // Declarative DAG endpoint: Kahn's sort routes inputs to engine.outputs.
  }
}
