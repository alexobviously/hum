import 'package:hum/hum.dart';

part 'audio_node_error.dart';

// TODO: do we need something like `bool needsUpdate()` or equality? for non equatable params (e.g. list in record)

abstract class const AudioNode<T extends AudioProcessor>() {
  List<Inlet> get inlets;
  List<Outlet> get outlets;

  /// Called when creating or recreating a processor for this node.
  T createProcessor();

  /// Properties of the node that _cannot_ be updated on the processor.
  /// If anything in this list changes, then the processor will be recreated.
  ///
  /// It isn't necessary to include port counts in this list, the default
  /// comparison already considers them.
  List<Object?> get fixedProps;

  /// Properties of the node that _can_ be updated on the processor.
  /// When dynamic props change, the processor will be updated by passing the
  /// [params] object from the host to the engine.
  List<Object?> get dynamicProps;

  /// The message that is sent from the host to the engine to update the
  /// processor. This can theoretically be anything that is able to cross an
  /// isolate boundary, but a [Record] type is recommended.
  ///
  /// The things you want to pass should be the same things in [dynamicProps],
  /// or derived from them (e.g. a [ControlParam] maps to [param.valueOrNull]).
  Object get params;

  /// Used to determine whether the configuration of this node is valid.
  /// If no errors are returned, it is valid.
  List<AudioNodeError> get errors => [];

  /// Whether this node's processor needs to be updated. Compares runtime type,
  /// port counts, [dynamicProps] and [fixedProps].
  ///
  /// You probably don't need to override this. Define [dynamicProps] and
  /// [fixedProps] instead.
  bool needsUpdate(AudioNode newNode) =>
      runtimeType != newNode.runtimeType ||
      inlets.length != newNode.inlets.length ||
      outlets.length != newNode.outlets.length ||
      !deepEquals(dynamicProps, newNode.dynamicProps) ||
      !deepEquals(fixedProps, newNode.fixedProps);

  /// Whether this node's processor can be safely updated in-place with
  /// [newNode]'s params. Compares runtime type, port counts, and [fixedProps].
  ///
  /// You probably don't need to override this. Define [fixedProps] instead.
  bool canUpdate(AudioNode newNode) =>
      runtimeType == newNode.runtimeType &&
      inlets.length == newNode.inlets.length &&
      outlets.length == newNode.outlets.length &&
      deepEquals(fixedProps, newNode.fixedProps);

  NodeComparisonResult compare(AudioNode newNode) {
    if (runtimeType != newNode.runtimeType) return .unrelated;

    if (!needsUpdate(newNode)) return .identical;
    if (canUpdate(newNode)) return .update;

    return .replace;
  }
}

enum NodeComparisonResult { identical, update, replace, unrelated }
