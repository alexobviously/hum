import 'dart:collection';

import 'package:hum/hum.dart';

/// The inclusive range of schedule steps over which an [Outlet]'s buffer holds
/// a value that is still needed.
///
/// A buffer becomes live at the step of the node that produces it ([start])
/// and stays live until the last step of a node that reads it ([end]).
typedef LiveRange = ({int start, int end});

/// The result of [allocateBufferSlots].
class const BufferAllocation({
  /// The virtual buffer slot assigned to every [Outlet] in the schedule.
  required final Map<Outlet, int> slots,

  /// The number of distinct slots, i.e. the size of the buffer pool needed.
  required final int totalSlots,
}) {
  /// Returns the slot assigned to [outlet].
  ///
  /// Throws a [StateError] if [outlet] was not part of the allocated schedule.
  int slotOf(Outlet outlet) =>
      slots[outlet] ?? (throw StateError('No slot allocated for $outlet.'));
}

/// Computes the [LiveRange] of every [Outlet] produced by [sortedNodes].
///
/// [sortedNodes] must be in execution order (see [topologicalSort]), and every
/// connected inlet must be fed by an outlet of a node that appears earlier in
/// the list. Outlets that nothing reads are live only during their own step.
///
/// Outlets in [pinned] (e.g. the graph's final outputs, which are read after
/// the last step) are kept live for the whole remainder of the schedule.
///
/// Throws an [ArgumentError] if the schedule is not a valid execution order, or
/// if a pinned outlet is not produced by [sortedNodes].
Map<Outlet, LiveRange> computeLiveRanges(
  List<AudioNode> sortedNodes, {
  Iterable<Outlet> pinned = const [],
}) {
  final ranges = <Outlet, LiveRange>{};

  for (final (step, node) in sortedNodes.indexed) {
    for (final inlet in node.inlets) {
      final source = inlet.source;
      if (source == null) continue;
      final range = ranges[source];
      if (range == null) {
        throw ArgumentError.value(
          sortedNodes,
          'sortedNodes',
          'Node $node reads $source before it is produced. '
              'Nodes must be in topological order.',
        );
      }
      ranges[source] = (start: range.start, end: step);
    }

    for (final outlet in node.outlets) {
      ranges[outlet] = (start: step, end: step);
    }
  }

  for (final outlet in pinned) {
    final range = ranges[outlet];
    if (range == null) {
      throw ArgumentError.value(
        outlet,
        'pinned',
        'Pinned outlet is not produced by any scheduled node.',
      );
    }
    ranges[outlet] = (start: range.start, end: sortedNodes.length);
  }

  return ranges;
}

// TODO(buffer-allocation): audit processors and opt safe 1-in/1-out nodes into
// `canProcessInPlace` when calling `allocateBufferSlots` from `compileGraph`.
/// Assigns virtual buffer slots to the outlets of [sortedNodes], reusing slots
/// whose contents are no longer needed.
///
/// This is register allocation for audio buffers. Liveness intervals are
/// computed with [computeLiveRanges], then a linear scan over the schedule
/// hands each node's outputs the lowest-numbered free slot. Because live
/// ranges are intervals, this is an optimal colouring: [BufferAllocation.totalSlots]
/// equals the maximum number of simultaneously live buffers.
///
/// This is a pure function of the graph structure. It does not allocate any
/// sample buffers, and never mutates [sortedNodes].
///
/// A node's outputs never share a slot with its own inputs, since a processor
/// is free to write an output before it has finished reading an input. The
/// exception is nodes for which [canProcessInPlace] returns `true`. For those,
/// output `i` may reuse the slot of input `i` when that input's last reader is
/// the node itself (and no other inlet of the node reads the same outlet).
/// [canProcessInPlace] must only return `true` for processors that can safely
/// read input `i` and write output `i` to the same buffer, sample by sample.
///
/// Outlets in [pinned] keep their slot for the whole schedule; pass the
/// graph's final output outlets here.
///
/// Slots are reused without being cleared, so an output buffer may contain
/// anything when a processor receives it. It is the processor's responsibility
/// to leave each output in the state it wants, zeroing it if necessary.
BufferAllocation allocateBufferSlots(
  List<AudioNode> sortedNodes, {
  Iterable<Outlet> pinned = const [],
  bool Function(AudioNode node)? canProcessInPlace,
}) {
  final ranges = computeLiveRanges(sortedNodes, pinned: pinned);

  // Outlets grouped by the last step in which they are live.
  final expiring = <int, List<Outlet>>{};
  for (final MapEntry(key: outlet, value: range) in ranges.entries) {
    (expiring[range.end] ??= []).add(outlet);
  }

  final slots = <Outlet, int>{};
  // Ordered so that the lowest free slot is always reused first.
  final free = SplayTreeSet<int>();
  // Outlets whose slot was handed over to an output of their final reader.
  final handedOver = <Outlet>{};
  int totalSlots = 0;

  for (final (step, node) in sortedNodes.indexed) {
    // Anything whose last use was the previous step can now be reused.
    for (final outlet in expiring[step - 1] ?? const <Outlet>[]) {
      if (!handedOver.contains(outlet)) free.add(slots[outlet]!);
    }

    final inPlace = canProcessInPlace?.call(node) ?? false;

    for (final (index, outlet) in node.outlets.indexed) {
      final reusable = inPlace
          ? _inPlaceSource(node, index, step, ranges)
          : null;

      if (reusable != null) {
        slots[outlet] = slots[reusable]!;
        handedOver.add(reusable);
      } else if (free.isNotEmpty) {
        final slot = free.first;
        free.remove(slot);
        slots[outlet] = slot;
      } else {
        slots[outlet] = totalSlots++;
      }
    }
  }

  return BufferAllocation(slots: slots, totalSlots: totalSlots);
}

/// Returns the outlet feeding inlet [index] of [node] if its buffer can be
/// overwritten by output [index] of [node], or `null` if not.
Outlet? _inPlaceSource(
  AudioNode node,
  int index,
  int step,
  Map<Outlet, LiveRange> ranges,
) {
  if (index >= node.inlets.length) return null;

  final source = node.inlets[index].source;
  if (source == null) return null;

  // The node must be the final reader of the buffer...
  if (ranges[source]!.end != step) return null;

  // ...and must read it through exactly one inlet, otherwise writing output
  // `index` would corrupt what another inlet reads.
  final readers = node.inlets.where((inlet) => inlet.source == source);
  return readers.length == 1 ? source : null;
}
