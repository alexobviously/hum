import 'dart:isolate';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Messages sent from [IsolateAudioHost] to the background audio isolate.
sealed class const HostToEngineMessage();

class const ApplyDiffMessage(final GraphDiff diff) extends HostToEngineMessage;

class const UpdateParamMessage(final int nodeId, final Object params)
    extends HostToEngineMessage;

class const RenderBlocksMessage(final int count, final SendPort replyPort)
    extends HostToEngineMessage;

class const DisposeMessage() extends HostToEngineMessage;

/// Top-level entrypoint for the background audio worker isolate.
void _audioWorkerEntry(
  ({SendPort hostSendPort, ProcessContext context}) args,
) {
  final workerReceivePort = ReceivePort();
  args.hostSendPort.send(workerReceivePort.sendPort);

  final engine = AudioEngine(context: args.context);

  workerReceivePort.listen((message) {
    switch (message) {
      case ApplyDiffMessage(:final diff):
        engine.applyDiff(diff);
      case UpdateParamMessage(:final nodeId, :final params):
        engine.updateParam(nodeId, params);
      case RenderBlocksMessage(:final count, :final replyPort):
        final numChannels = engine.numChannels;
        final totalBlocks = <Float32List>[];
        for (int i = 0; i < count; i++) {
          engine.process();
          for (int ch = 0; ch < numChannels; ch++) {
            totalBlocks.add(.fromList(engine.outputs[ch]));
          }
        }
        replyPort.send(totalBlocks);
      case DisposeMessage():
        workerReceivePort.close();
    }
  });
}

/// Multi-threaded isolate implementation of [AudioHost].
class IsolateAudioHost extends AudioHost {
  @override
  final ProcessContext context;

  final Isolate _isolate;
  final SendPort _engineSendPort;
  GraphSnapshot _currentSnapshot = .empty;
  bool _isDisposed = false;

  IsolateAudioHost._({
    required this.context,
    required this._isolate,
    required this._engineSendPort,
  });

  /// Spawns a new background worker isolate running [AudioEngine].
  static Future<IsolateAudioHost> spawn({
    required ProcessContext context,
  }) async {
    final hostReceivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _audioWorkerEntry,
      (hostSendPort: hostReceivePort.sendPort, context: context),
    );

    final engineSendPort = await hostReceivePort.first as SendPort;

    return IsolateAudioHost._(
      context: context,
      isolate: isolate,
      engineSendPort: engineSendPort,
    );
  }

  @override
  GraphSnapshot get currentSnapshot => _currentSnapshot;

  @override
  List<NodeDiagnostic> setGraph({
    AudioNode? root,
    List<AudioNode>? roots,
    List<Outlet>? targetOutputs,
  }) {
    if (_isDisposed) {
      throw StateError('Cannot setGraph on a disposed AudioHost.');
    }

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
      _engineSendPort.send(ApplyDiffMessage(diff));
    }

    _currentSnapshot = diff.snapshot;
    return const [];
  }

  @override
  void update(AudioNode node, Object params) {
    if (_isDisposed) return;
    final id = _currentSnapshot.nodeIds[node];
    if (id != null) {
      _engineSendPort.send(UpdateParamMessage(id, params));
    }
  }

  @override
  void updateById(int nodeId, Object params) {
    if (_isDisposed) return;
    _engineSendPort.send(UpdateParamMessage(nodeId, params));
  }

  @override
  Future<List<Float32List>> renderBlocks(int count) async {
    if (_isDisposed) {
      throw StateError('Cannot renderBlocks on a disposed AudioHost.');
    }
    final replyPort = ReceivePort();
    _engineSendPort.send(RenderBlocksMessage(count, replyPort.sendPort));
    final blocks = await replyPort.first as List<Float32List>;
    return blocks;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _engineSendPort.send(const DisposeMessage());
    _isolate.kill(priority: Isolate.immediate);
  }
}
