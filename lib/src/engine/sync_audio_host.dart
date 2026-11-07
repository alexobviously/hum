import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Synchronous single-threaded implementation of [AudioHost].
class SyncAudioHost extends AudioHost {
  @override
  final ProcessContext context;

  final AudioEngine _engine;
  GraphSnapshot _currentSnapshot = GraphSnapshot.empty;

  SyncAudioHost({required this.context})
    : _engine = AudioEngine(context: context);

  /// The underlying [AudioEngine] instance.
  AudioEngine get engine => _engine;

  @override
  GraphSnapshot get currentSnapshot => _currentSnapshot;

  /// The number of output channels currently configured.
  @override
  int get numChannels => _engine.numChannels;

  /// The active output buffers of the engine.
  List<Float32List> get outputs => _engine.outputs;

  @override
  List<NodeDiagnostic> setGraph({
    AudioNode? root,
    List<AudioNode>? roots,
    List<Outlet>? targetOutputs,
  }) {
    final result = compileGraph(
      root: root,
      roots: roots,
      targetOutputs: targetOutputs,
    );

    if (result.isFailure) {
      return result.diagnostics;
    }

    final newSnapshot = result.snapshot!;
    final diff = diffGraph(_currentSnapshot, newSnapshot);

    if (diff.isNotEmpty) {
      _engine.applyDiff(diff);
    }

    _currentSnapshot = diff.snapshot;
    return const [];
  }

  @override
  void update(AudioNode node, Object params) {
    final id = _currentSnapshot.nodeIds[node];
    if (id != null) {
      _engine.updateParam(id, params);
    }
  }

  @override
  void updateById(int nodeId, Object params) {
    _engine.updateParam(nodeId, params);
  }

  /// Processes one block of audio synchronously.
  void process() {
    _engine.process();
  }

  @override
  Future<List<Float32List>> renderBlocks(int count) async {
    final numChannels = _engine.numChannels;
    final totalBlocks = <Float32List>[];
    for (int i = 0; i < count; i++) {
      _engine.process();
      for (int ch = 0; ch < numChannels; ch++) {
        totalBlocks.add(Float32List.fromList(_engine.outputs[ch]));
      }
    }
    return totalBlocks;
  }

  /// Retrieves the active processor for [node], or null if not registered.
  T? processorOf<T extends AudioProcessor>(AudioNode node) {
    final id = _currentSnapshot.nodeIds[node];
    return id != null ? _engine.processorOf<T>(id) : null;
  }

  @override
  Future<void> dispose() async {
    // No background threads to terminate.
  }
}
