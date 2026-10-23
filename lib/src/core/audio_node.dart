import 'package:hum/hum.dart';

part 'audio_node_error.dart';

abstract class AudioNode<T extends AudioProcessor> {
  const AudioNode();

  List<Inlet> get inlets;
  List<Outlet> get outlets;

  T createProcessor();

  Object get params;

  /// Used to determine whether the configuration of this node is valid.
  /// If no errors are returned, it is valid.
  List<AudioNodeError> get errors => [];

  /// Whether this node's processor can be safely updated in-place with
  /// [newNode]'s params.
  bool canUpdate(AudioNode newNode) => runtimeType == newNode.runtimeType;
}
