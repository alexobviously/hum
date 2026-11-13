import 'dart:collection';

import 'package:hum/hum.dart';

// TODO: consider structured error/diagnostic not cycle?
class GraphCycleException implements Exception {
  final String message;
  GraphCycleException([this.message = 'Audio graph contains a cycle.']);

  @override
  String toString() => 'GraphCycleException: $message';
}

/// Discovers all reachable [AudioNode]s by walking backwards from the given [roots].
Set<AudioNode> discoverNodes(Iterable<AudioNode> roots) {
  final visited = <AudioNode>{};
  final queue = <AudioNode>[...roots];

  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    if (!visited.add(current)) continue;

    for (final inlet in current.inlets) {
      final upstream = inlet.source?.node;
      if (upstream != null && !visited.contains(upstream)) {
        queue.add(upstream);
      }
    }
  }

  return visited;
}

/// Topologically sorts [nodes] using Kahn's algorithm.
///
/// Throws [GraphCycleException] if a cycle is detected.
List<AudioNode> topologicalSort(Set<AudioNode> nodes) {
  final dependents = <AudioNode, List<AudioNode>>{
    for (final node in nodes) node: [],
  };
  final inDegree = <AudioNode, int>{for (final node in nodes) node: 0};

  // Build the dependency graph
  for (final consumer in nodes) {
    final upstreamNodes = consumer.inlets
        .map((inlet) => inlet.source?.node)
        .whereType<AudioNode>()
        .toSet();
    inDegree[consumer] = upstreamNodes.length;

    for (final producer in upstreamNodes) {
      dependents[producer]?.add(consumer);
    }
  }

  // Seed queue with source nodes (in-degree == 0)
  final queue = Queue<AudioNode>.from(
    nodes.where((node) => inDegree[node] == 0),
  );

  final sorted = <AudioNode>[];

  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    sorted.add(current);

    for (final consumer in dependents[current]!) {
      final updatedDegree = inDegree[consumer]! - 1;
      inDegree[consumer] = updatedDegree;
      if (updatedDegree == 0) {
        queue.add(consumer);
      }
    }
  }

  if (sorted.length != nodes.length) {
    throw GraphCycleException(
      'Cycle detected in audio graph. Feedback loops require an explicit delay node.',
    );
  }

  return sorted;
}

/// The result of compiling an audio graph into a [GraphSnapshot].
typedef CompileGraphResult = ({
  GraphSnapshot? snapshot,
  List<NodeDiagnostic> diagnostics,
});

extension CompileGraphResultExtension on CompileGraphResult {
  /// Whether compilation succeeded and produced a [GraphSnapshot].
  bool get isSuccess => switch (snapshot) {
    null => false,
    _ => true,
  };

  /// Whether compilation failed due to node validation errors.
  bool get isFailure => !isSuccess;

  /// Whether any diagnostics were reported.
  bool get hasErrors => diagnostics.isNotEmpty;
}

/// The result of compiling an audio graph into an [AudioPipeline].
typedef CompileResult = ({
  AudioPipeline? pipeline,
  List<NodeDiagnostic> diagnostics,
});

extension CompileResultExtension on CompileResult {
  /// Whether compilation succeeded and produced an [AudioPipeline].
  bool get isSuccess => switch (pipeline) {
    null => false,
    _ => true,
  };

  /// Whether compilation failed due to node validation errors.
  bool get isFailure => !isSuccess;

  /// Whether any diagnostics were reported.
  bool get hasErrors => diagnostics.isNotEmpty;
}

/// Validates reachable nodes starting from [roots], returning a diagnostic for
/// each node that has errors.
List<NodeDiagnostic> validateGraph(Iterable<AudioNode> roots) {
  final discovered = discoverNodes(roots);
  return [
    for (final node in discovered)
      if (node.errors.isNotEmpty)
        NodeDiagnostic(node: node, errors: node.errors),
  ];
}

/// Compiles a declarative audio graph into a statically validated [GraphSnapshot].
///
/// Discovers reachable nodes, validates parameter constraints, sorts topologically
/// via Kahn's algorithm, and assigns virtual buffer slots. Does not allocate physical
/// sample buffers or instantiate [AudioProcessor]s.
CompileGraphResult compileGraph({
  AudioNode? root,
  List<AudioNode>? roots,
  List<Outlet>? targetOutputs,
}) {
  final resolvedRoots = <AudioNode>{
    ?root,
    ...?roots,
    if (targetOutputs != null) ...targetOutputs.map((p) => p.node),
  };

  if (resolvedRoots.isEmpty) {
    throw ArgumentError(
      'At least one root node or targetOutput must be provided.',
    );
  }

  // 1. Discover all reachable nodes
  final discovered = discoverNodes(resolvedRoots);

  // 2. Validate all reachable nodes
  final diagnostics = [
    for (final node in discovered)
      if (node.errors.isNotEmpty)
        NodeDiagnostic(node: node, errors: node.errors),
  ];

  // Right now, all diagnostics are errors, we could consider adding warnings too.
  if (diagnostics.isNotEmpty) {
    return (snapshot: null, diagnostics: diagnostics);
  }

  // 3. Linearize execution order via Kahn's algorithm
  final sortedNodes = topologicalSort(discovered);

  // 4. Virtual buffer slot allocation
  // TODO(buffer-allocation): replace this one-slot-per-outlet scheme with
  // `allocateBufferSlots(sortedNodes, pinned: <final output outlets>)` from
  // buffer_allocation.dart. Not wired up yet: processors that cache buffer
  // views need invalidating when slots change (topology epoch), and we need to
  // decide which nodes opt in to in-place processing. See the TODO there.
  final outletSlots = <Outlet, int>{};
  int nextSlot = 0;

  int getSlot(Outlet outlet) {
    return outletSlots.putIfAbsent(outlet, () => nextSlot++);
  }

  for (final node in sortedNodes) {
    for (final outlet in node.outlets) {
      getSlot(outlet);
    }
  }

  // 5. Create SnapshotSteps
  final steps = [
    for (final node in sortedNodes)
      SnapshotStep(
        node: node,
        inputSlots: [
          for (final inlet in node.inlets)
            inlet.source != null ? getSlot(inlet.source!) : -1,
        ],
        outputSlots: [
          for (final outlet in node.outlets) getSlot(outlet),
        ],
      ),
  ];

  // 6. Determine graph output slots
  List<Outlet> extractOutputs(AudioNode node) => switch (node) {
    Out(:final channels) => channels,
    TerminalNode(:final inlets) => [for (final i in inlets) ?i.source],
    AudioNode(:final outlets) when outlets.isNotEmpty => outlets,
    AudioNode(:final inlets) => [for (final i in inlets) ?i.source],
  };

  final finalOutputPorts = switch ((targetOutputs, root)) {
    (final targets?, _) => targets,
    (_, final root?) => extractOutputs(root),
    _ => [for (final r in resolvedRoots) ...extractOutputs(r)],
  };

  final graphOutputSlots = [
    for (final outlet in finalOutputPorts) getSlot(outlet),
  ];

  final snapshot = GraphSnapshot(
    nodes: sortedNodes,
    steps: steps,
    totalSlots: nextSlot,
    outputSlots: graphOutputSlots,
  );

  return (snapshot: snapshot, diagnostics: const []);
}

/// Compiles a declarative audio graph into an executable [AudioPipeline].
CompileResult compilePipeline({
  AudioNode? root,
  List<AudioNode>? roots,
  List<Outlet>? targetOutputs,
  required ProcessContext context,
}) {
  final graphResult = compileGraph(
    root: root,
    roots: roots,
    targetOutputs: targetOutputs,
  );

  if (graphResult.isFailure) {
    return (
      pipeline: null,
      diagnostics: graphResult.diagnostics,
    );
  }

  final snapshot = graphResult.snapshot!;
  final pipeline = snapshot.toPipeline(context);

  return (
    pipeline: pipeline,
    diagnostics: const [],
  );
}
