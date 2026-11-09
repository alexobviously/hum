import 'dart:math' as math;

import 'package:hum/hum.dart';

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A single step's virtual buffer slot wiring in the execution schedule.
class const RenderStepPlan({
  required final int nodeId,
  required final List<int> inputSlots,
  required final List<int> outputSlots,
}) {
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderStepPlan &&
          nodeId == other.nodeId &&
          _listEquals(inputSlots, other.inputSlots) &&
          _listEquals(outputSlots, other.outputSlots);

  @override
  int get hashCode => Object.hash(
    nodeId,
    Object.hashAll(inputSlots),
    Object.hashAll(outputSlots),
  );
}

/// The complete execution schedule and virtual buffer slot requirements.
class const RenderSchedulePlan({
  required final int totalSlotsRequired,
  required final List<RenderStepPlan> steps,
  required final List<int> outputSlots,
}) {
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderSchedulePlan &&
          totalSlotsRequired == other.totalSlotsRequired &&
          _listEquals(outputSlots, other.outputSlots) &&
          _listEquals(steps, other.steps);

  @override
  int get hashCode => Object.hash(
    totalSlotsRequired,
    Object.hashAll(outputSlots),
    Object.hashAll(steps),
  );
}

/// The result of diffing two [GraphSnapshot]s.
///
/// Contains minimal instructions for the audio engine to update its state
/// at a block boundary.
class const GraphDiff({
  final Map<int, AudioNode> addedNodes = const {},
  final Map<int, Object> updatedParams = const {},
  final List<int> removedNodeIds = const [],
  final RenderSchedulePlan? newSchedule,
  required final GraphSnapshot snapshot,
}) {
  /// Whether this diff contains no changes.
  bool get isEmpty =>
      addedNodes.isEmpty &&
      updatedParams.isEmpty &&
      removedNodeIds.isEmpty &&
      newSchedule == null;

  /// Whether this diff contains changes for the engine to apply.
  bool get isNotEmpty => !isEmpty;

  /// Whether the execution schedule or buffer wiring changed.
  bool get hasScheduleChange => newSchedule != null;
}

/// Computes the minimal transactional delta between [oldSnapshot] and [newSnapshot].
GraphDiff diffGraph(GraphSnapshot oldSnapshot, GraphSnapshot newSnapshot) {
  if (oldSnapshot.isEmpty && newSnapshot.isEmpty) {
    return GraphDiff(snapshot: newSnapshot);
  }

  if (newSnapshot.isEmpty) {
    return GraphDiff(
      removedNodeIds: oldSnapshot.nodeIds.values.toList(),
      snapshot: newSnapshot,
    );
  }

  // Determine starting ID for new node instantiations
  int nextId = oldSnapshot.nodeIds.values.fold<int>(-1, math.max) + 1;

  final oldNodes = oldSnapshot.nodes;
  final newNodes = newSnapshot.nodes;

  final matchedOldToNew = <AudioNode, AudioNode>{};
  final matchedNewToOld = <AudioNode, AudioNode>{};
  final matchedNewIds = <AudioNode, int>{};

  // Pass 1: Match by exact instance identity
  for (final newNode in newNodes) {
    for (final oldNode in oldNodes) {
      if (!matchedOldToNew.containsKey(oldNode) &&
          identical(oldNode, newNode)) {
        final oldId = oldSnapshot.nodeIds[oldNode];
        if (oldId != null) {
          matchedOldToNew[oldNode] = newNode;
          matchedNewToOld[newNode] = oldNode;
          matchedNewIds[newNode] = oldId;
          break;
        }
      }
    }
  }

  final addedNodes = <int, AudioNode>{};
  final updatedParams = <int, Object>{};
  final removedNodeIds = <int>[];

  // Pass 2: Match compatible nodes of same type
  for (final newNode in newNodes) {
    if (matchedNewToOld.containsKey(newNode)) continue;
    for (final oldNode in oldNodes) {
      if (matchedOldToNew.containsKey(oldNode)) continue;
      final comparison = oldNode.compare(newNode);
      if (comparison == .identical || comparison == .update) {
        final oldId = oldSnapshot.nodeIds[oldNode];
        if (oldId != null) {
          matchedOldToNew[oldNode] = newNode;
          matchedNewToOld[newNode] = oldNode;
          matchedNewIds[newNode] = oldId;
          if (comparison == .update) {
            updatedParams[oldId] = newNode.params;
          }
          break;
        }
      }
    }
  }

  // Unmatched new nodes: assign new IDs and mark for creation
  for (final newNode in newNodes) {
    if (!matchedNewToOld.containsKey(newNode)) {
      final id = nextId++;
      matchedNewIds[newNode] = id;
      addedNodes[id] = newNode;
    }
  }

  // Unmatched old nodes: mark for removal
  for (final oldNode in oldNodes) {
    if (!matchedOldToNew.containsKey(oldNode)) {
      final id = oldSnapshot.nodeIds[oldNode];
      if (id != null) {
        removedNodeIds.add(id);
      }
    }
  }

  // Build the candidate schedule for newSnapshot
  final candidateSteps = [
    for (final step in newSnapshot.steps)
      RenderStepPlan(
        nodeId: matchedNewIds[step.node]!,
        inputSlots: step.inputSlots,
        outputSlots: step.outputSlots,
      ),
  ];

  final candidateSchedule = RenderSchedulePlan(
    totalSlotsRequired: newSnapshot.totalSlots,
    steps: candidateSteps,
    outputSlots: newSnapshot.outputSlots,
  );

  // Check if schedule changed compared to oldSnapshot
  RenderSchedulePlan? scheduleToEmit;
  if (oldSnapshot.isEmpty ||
      addedNodes.isNotEmpty ||
      removedNodeIds.isNotEmpty ||
      oldSnapshot.steps.length != newSnapshot.steps.length ||
      oldSnapshot.totalSlots != newSnapshot.totalSlots ||
      !_listEquals(oldSnapshot.outputSlots, newSnapshot.outputSlots)) {
    scheduleToEmit = candidateSchedule;
  } else {
    bool stepsDiffer = false;
    for (int i = 0; i < newSnapshot.steps.length; i++) {
      final oldStep = oldSnapshot.steps[i];
      final newStepPlan = candidateSteps[i];
      final oldId = oldSnapshot.nodeIds[oldStep.node];
      if (oldId != newStepPlan.nodeId ||
          !_listEquals(oldStep.inputSlots, newStepPlan.inputSlots) ||
          !_listEquals(oldStep.outputSlots, newStepPlan.outputSlots)) {
        stepsDiffer = true;
        break;
      }
    }
    if (stepsDiffer) {
      scheduleToEmit = candidateSchedule;
    }
  }

  final reconciledSnapshot = newSnapshot.withNodeIds(matchedNewIds);

  return GraphDiff(
    addedNodes: addedNodes,
    updatedParams: updatedParams,
    removedNodeIds: removedNodeIds,
    newSchedule: scheduleToEmit,
    snapshot: reconciledSnapshot,
  );
}
