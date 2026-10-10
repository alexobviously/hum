import 'dart:collection';
import 'dart:typed_data';

import 'package:dsp/dsp.dart';

export 'package:dsp/src/compiler/pipeline.dart';

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

/// Compiles a declarative audio graph into an executable [AudioPipeline].
AudioPipeline compilePipeline({
  AudioNode? root,
  List<AudioNode>? roots,
  List<Outlet>? targetOutputs,
  required ProcessContext context,
  ProcessorRegistry? processorRegistry,
}) {
  processorRegistry ??= defaultRegistry();

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

  // 2. Linearize execution order via Kahn's algorithm
  final sortedNodes = topologicalSort(discovered);

  // 3. Buffer allocation & mapping
  // Map every unique Outlet to a pre-allocated Float32List
  final outletBuffers = <Outlet, Float32List>{};

  Float32List getBuffer(Outlet outlet) {
    return outletBuffers.putIfAbsent(
      outlet,
      () => Float32List(context.vectorSize),
    );
  }

  // Pre-allocate for all declared outlets of active nodes
  for (final node in sortedNodes) {
    for (final outlet in node.outlets) {
      getBuffer(outlet);
    }
  }

  final emptyBuffer = Float32List(context.vectorSize);

  // 4. Create RenderSteps
  final steps = <RenderStep>[];
  for (final node in sortedNodes) {
    final processor = processorRegistry.build(
      processorRegistry.keyForNode(node),
      node.params,
    );
    final stepInputs = [
      for (final inlet in node.inlets)
        inlet.source != null ? getBuffer(inlet.source!) : emptyBuffer,
    ];
    final stepOutputs = [for (final outlet in node.outlets) getBuffer(outlet)];

    steps.add(
      RenderStep(
        node: node,
        processor: processor,
        inputs: stepInputs,
        outputs: stepOutputs,
      ),
    );
  }

  // 5. Determine pipeline outputs
  List<Outlet> finalOutputPorts;
  if (targetOutputs != null) {
    finalOutputPorts = targetOutputs;
  } else if (root != null) {
    finalOutputPorts = root.outlets.isNotEmpty
        ? root.outlets
        : [for (final inlet in root.inlets) ?inlet.source];
  } else {
    finalOutputPorts = [
      for (final r in resolvedRoots)
        ...(r.outlets.isNotEmpty
            ? r.outlets
            : [for (final inlet in r.inlets) ?inlet.source]),
    ];
  }

  final pipelineOutputs = [
    for (final outlet in finalOutputPorts) getBuffer(outlet),
  ];

  return AudioPipeline(
    context: context,
    processorRegistry: processorRegistry,
    steps: steps,
    outputs: pipelineOutputs,
  );
}
