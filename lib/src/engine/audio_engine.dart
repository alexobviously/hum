import 'dart:typed_data';

import 'package:hum/hum.dart';

/// A single step in the engine's linear execution schedule.
class const EngineStep({
  required final AudioProcessor processor,
  required final List<Float32List> inputs,
  required final List<Float32List> outputs,
}) {
  /// Executes this processor synchronously using its pre-mapped buffers.
  @pragma('vm:prefer-inline')
  void process(ProcessContext context) {
    processor.process(context, inputs, outputs);
  }
}

/// The runtime audio execution engine.
///
/// Owns the active [AudioProcessor] instances, pre-allocated memory buffer pool,
/// and linear execution schedule. Receives transactional [GraphDiff] updates at
/// block boundaries with zero allocations during the real-time [process] loop.
class AudioEngine({required final ProcessContext context}) {
  final Map<int, AudioProcessor> _processors = {};
  final List<Float32List> _bufferPool = [];
  late final Float32List _emptyBuffer = Float32List(context.vectorSize);

  List<EngineStep> _steps = [];
  List<Float32List> _outputs = [];

  /// The active output buffers of the engine (one [Float32List] per output channel).
  List<Float32List> get outputs => _outputs;

  /// The number of output channels.
  int get numChannels => _outputs.length;

  /// The number of currently instantiated processors.
  int get processorCount => _processors.length;

  /// The number of execution steps in the current schedule.
  int get stepCount => _steps.length;

  /// The number of buffers in the allocated buffer pool.
  int get bufferPoolSize => _bufferPool.length;

  /// Retrieves the active processor for [nodeId], or null if not registered.
  T? processorOf<T extends AudioProcessor>(int nodeId) =>
      switch (_processors[nodeId]) {
        final T p => p,
        _ => null,
      };

  /// Applies a [GraphDiff] transaction at a block boundary.
  void applyDiff(GraphDiff diff) {
    // 1. Instantiate new processors
    for (final MapEntry(key: id, value: node) in diff.addedNodes.entries) {
      _processors[id] = node.createProcessor();
    }

    // 2. In-place parameter updates
    for (final MapEntry(key: id, value: params) in diff.updatedParams.entries) {
      _processors[id]?.update(params);
    }

    // 3. Drop removed processors
    for (final id in diff.removedNodeIds) {
      _processors.remove(id);
    }

    // 4. Rebuild schedule and buffer pool if topology changed
    if (diff.newSchedule case final schedule?) {
      while (_bufferPool.length < schedule.totalSlotsRequired) {
        _bufferPool.add(Float32List(context.vectorSize));
      }

      _steps = [
        for (final step in schedule.steps)
          EngineStep(
            processor: _processors[step.nodeId]!,
            inputs: [
              for (final slot in step.inputSlots)
                slot >= 0 ? _bufferPool[slot] : _emptyBuffer,
            ],
            outputs: [
              for (final slot in step.outputSlots) _bufferPool[slot],
            ],
          ),
      ];

      _outputs = [
        for (final slot in schedule.outputSlots) _bufferPool[slot],
      ];
    }
  }

  /// Fast-path direct parameter update for [nodeId] (bypasses graph diffing).
  void updateParam(int nodeId, Object params) {
    _processors[nodeId]?.update(params);
  }

  /// Processes one block of audio across all scheduled nodes.
  ///
  /// Zero heap allocations occur during this call.
  @pragma('vm:prefer-inline')
  void process() {
    for (int i = 0; i < _steps.length; i++) {
      _steps[i].process(context);
    }
  }
}
