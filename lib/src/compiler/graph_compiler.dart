import 'dart:collection';
import 'dart:typed_data';

import 'package:dsp/src/compiler/pipeline.dart';
import 'package:dsp/src/core/audio_node.dart';
import 'package:dsp/src/core/audio_port.dart';
import 'package:dsp/src/core/process_context.dart';

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

    for (final port in current.inputs) {
      if (!visited.contains(port.node)) {
        queue.add(port.node);
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
    final upstreamNodes = consumer.inputs.map((p) => p.node).toSet();
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
  List<AudioPort>? targetOutputs,
  required ProcessContext context,
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

  // 2. Linearize execution order via Kahn's algorithm
  final sortedNodes = topologicalSort(discovered);

  // 3. Buffer allocation & mapping
  // Map every unique AudioPort to a pre-allocated Float32List
  final portBuffers = <AudioPort, Float32List>{};

  Float32List getBuffer(AudioPort port) {
    return portBuffers.putIfAbsent(port, () => Float32List(context.vectorSize));
  }

  // Pre-allocate for all declared outputs of active nodes
  for (final node in sortedNodes) {
    for (final port in node.outputs) {
      getBuffer(port);
    }
  }

  // 4. Create RenderSteps
  final steps = <RenderStep>[];
  for (final node in sortedNodes) {
    final processor = node.createProcessor();
    final stepInputs = [for (final port in node.inputs) getBuffer(port)];
    final stepOutputs = [for (final port in node.outputs) getBuffer(port)];

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
  List<AudioPort> finalOutputPorts;
  if (targetOutputs != null) {
    finalOutputPorts = targetOutputs;
  } else if (root != null) {
    finalOutputPorts = root.outputs.isNotEmpty ? root.outputs : root.inputs;
  } else {
    finalOutputPorts = [
      for (final r in resolvedRoots)
        ...(r.outputs.isNotEmpty ? r.outputs : r.inputs),
    ];
  }

  final pipelineOutputs = [
    for (final port in finalOutputPorts) getBuffer(port),
  ];

  return AudioPipeline(
    context: context,
    steps: steps,
    outputs: pipelineOutputs,
  );
}
