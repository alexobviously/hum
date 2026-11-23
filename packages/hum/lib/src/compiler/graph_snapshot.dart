import 'dart:typed_data';

import 'package:hum/hum.dart';

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A declarative blueprint for one node's step in a graph schedule.
class const SnapshotStep({
  required final AudioNode node,
  required final List<int> inputSlots,
  required final List<int> outputSlots,
}) {
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SnapshotStep &&
          identical(node, other.node) &&
          _listEquals(inputSlots, other.inputSlots) &&
          _listEquals(outputSlots, other.outputSlots);

  @override
  int get hashCode => Object.hash(
    node,
    Object.hashAll(inputSlots),
    Object.hashAll(outputSlots),
  );
}

/// An immutable, statically compiled snapshot of an audio graph's topology,
/// execution schedule, and virtual buffer slot assignments.
class const GraphSnapshot({
  required final List<AudioNode> nodes,
  required final List<SnapshotStep> steps,
  required final int totalSlots,
  required final List<int> outputSlots,
  final Map<AudioNode, int> nodeIds = const {},
}) {
  /// An empty initial snapshot.
  static const empty = GraphSnapshot(
    nodes: [],
    steps: [],
    totalSlots: 0,
    outputSlots: [],
    nodeIds: {},
  );

  /// Whether this snapshot contains no nodes.
  bool get isEmpty => nodes.isEmpty;

  /// Whether this snapshot contains at least one node.
  bool get isNotEmpty => !isEmpty;

  /// Creates a copy of this snapshot with updated [nodeIds].
  GraphSnapshot withNodeIds(Map<AudioNode, int> nodeIds) => GraphSnapshot(
    nodes: nodes,
    steps: steps,
    totalSlots: totalSlots,
    outputSlots: outputSlots,
    nodeIds: nodeIds,
  );

  /// Materializes an executable [AudioPipeline] from this snapshot.
  ///
  /// Allocates physical memory buffers based on [totalSlots] and instantiates
  /// an [AudioProcessor] for each scheduled node. If [buffers] is provided,
  /// any [BufferAwareProcessor]s are bound to it immediately.
  AudioPipeline toPipeline(
    ProcessContext context, {
    Map<BufferId, AudioBuffer>? buffers,
  }) {
    final slotBuffers = List.generate(
      totalSlots,
      (_) => Float32List(context.vectorSize),
    );
    final emptyBuffer = Float32List(context.vectorSize);

    final pipelineSteps = <RenderStep>[];
    for (final step in steps) {
      final processor = step.node.createProcessor();
      if (buffers != null && processor is BufferAwareProcessor) {
        processor.bindBuffers((id) => buffers[id]);
      }
      final inputs = [
        for (final slot in step.inputSlots)
          slot >= 0 ? slotBuffers[slot] : emptyBuffer,
      ];
      final outputs = [
        for (final slot in step.outputSlots) slotBuffers[slot],
      ];
      pipelineSteps.add(
        RenderStep(
          node: step.node,
          processor: processor,
          inputs: inputs,
          outputs: outputs,
        ),
      );
    }

    final pipelineOutputs = [
      for (final slot in outputSlots) slotBuffers[slot],
    ];

    return AudioPipeline(
      context: context,
      steps: pipelineSteps,
      outputs: pipelineOutputs,
    );
  }
}
