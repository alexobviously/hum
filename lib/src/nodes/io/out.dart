import 'dart:typed_data';

import 'package:hum/hum.dart';

/// The declarative master output terminal node of an audio graph.
///
/// Upstream signals connected to [channels] are automatically designated as the graph's
/// master output channels in [compileGraph].
class Out({
  required final List<Outlet> channels,
}) extends TerminalNode<OutProcessor> {
  /// Creates a single-channel mono master output terminal node.
  Out.mono(Outlet channel) : this(channels: [channel]);

  /// Creates a two-channel stereo master output terminal node.
  Out.stereo({required Outlet left, required Outlet right})
    : this(channels: [left, right]);

  @override
  List<Inlet> get inlets => List.generate(
    channels.length,
    (i) => Inlet(node: this, index: i, source: channels[i]),
  );

  @override
  OutProcessor createProcessor() => const OutProcessor();

  @override
  Object get params => ();

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeParamError(param: 'channels', error: 'must not be empty'),
  ];

  @override
  bool canUpdate(AudioNode newNode) =>
      super.canUpdate(newNode) &&
      newNode is Out &&
      channels.length == newNode.channels.length;
}

/// The runtime processor for [Out].
class const OutProcessor() implements AudioProcessor {
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

/// Backwards compatibility alias for [Out].
@Deprecated('Use Out instead of Dac')
typedef Dac = Out;

/// Ergonomic extension shorthands for creating [Out] terminal nodes.
extension AudioNodeOutExtension on AudioNode {
  /// Wraps this node's outlets in an [Out] terminal node.
  Out get out =>
      outlets.length == 1 ? Out.mono(outlets.first) : Out(channels: outlets);
}

extension OutletOutExtension on Outlet {
  /// Wraps this outlet in a single-channel [Out.mono] terminal node.
  Out get out => Out.mono(this);
}

extension OutletListOutExtension on List<Outlet> {
  /// Wraps these outlets in a multi-channel [Out] terminal node.
  Out get out => Out(channels: this);
}
