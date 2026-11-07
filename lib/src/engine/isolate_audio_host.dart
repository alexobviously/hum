import 'dart:async';
import 'dart:io';
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

class const StartPlaybackMessage(final SendPort audioDataPort)
    extends HostToEngineMessage;

class const StopPlaybackMessage(final SendPort replyPort)
    extends HostToEngineMessage;

class const DisposeMessage([final SendPort? replyPort])
    extends HostToEngineMessage;

/// Top-level entrypoint for the background audio worker isolate.
void _audioWorkerEntry(
  ({SendPort hostSendPort, ProcessContext context}) args,
) {
  final workerReceivePort = ReceivePort();
  args.hostSendPort.send(workerReceivePort.sendPort);

  final engine = AudioEngine(context: args.context);
  final context = args.context;

  bool isPlaying = false;
  SendPort? activeAudioPort;
  SendPort? pendingStopReplyPort;

  void runPlaybackLoop() async {
    final sampleRate = context.sampleRate;
    final vectorSize = context.vectorSize;
    final blockDurationUs = (vectorSize * 1000000) ~/ sampleRate;
    final targetLeadUs = blockDurationUs * 2 > 25000
        ? blockDurationUs * 2
        : 25000;

    final stopwatch = Stopwatch()..start();
    int renderedSamples = 0;

    while (isPlaying) {
      final renderedTimeUs = (renderedSamples * 1000000) ~/ sampleRate;
      final elapsedUs = stopwatch.elapsedMicroseconds;

      if (elapsedUs - renderedTimeUs > 100000) {
        renderedSamples = (elapsedUs * sampleRate) ~/ 1000000;
      }

      final leadUs = ((renderedSamples * 1000000) ~/ sampleRate) - elapsedUs;
      if (leadUs > targetLeadUs) {
        final sleepUs = leadUs - targetLeadUs;
        if (sleepUs >= 1000) {
          await Future.delayed(Duration(microseconds: sleepUs));
        } else {
          await Future.delayed(Duration.zero);
        }
        if (!isPlaying) break;
      }

      engine.process();
      final numChannels = engine.numChannels;
      final channelCopies = <Float32List>[
        for (int ch = 0; ch < numChannels; ch++) .fromList(engine.outputs[ch]),
      ];
      activeAudioPort?.send(channelCopies);
      renderedSamples += vectorSize;
    }

    stopwatch.stop();
    pendingStopReplyPort?.send(null);
    pendingStopReplyPort = null;
  }

  workerReceivePort.listen((message) async {
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
      case StartPlaybackMessage(:final audioDataPort):
        if (!isPlaying) {
          isPlaying = true;
          activeAudioPort = audioDataPort;
          runPlaybackLoop();
        }
      case StopPlaybackMessage(:final replyPort):
        if (isPlaying) {
          isPlaying = false;
          pendingStopReplyPort = replyPort;
        } else {
          replyPort.send(null);
        }
      case DisposeMessage(:final replyPort):
        isPlaying = false;
        await engine.dispose();
        replyPort?.send(null);
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
  bool _isPlaying = false;
  ReceivePort? _audioReceivePort;

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

  // TODO: DRY THIS, maybe rethink
  @override
  Future<Uint8List> exportWav({
    String? path,
    required Duration duration,
    WavFormat format = .float32,
  }) async {
    if (numChannels == 0) {
      throw StateError(
        'No active audio graph to export. Call setGraph() first.',
      );
    }
    final sampleRate = context.sampleRate;
    final vectorSize = context.vectorSize;
    final totalSamples = (sampleRate * duration.inMicroseconds) ~/ 1000000;
    final totalBlocks = (totalSamples + vectorSize - 1) ~/ vectorSize;

    final renderedBlocks = await renderBlocks(totalBlocks);
    final interleaver = BufferInterleaver(
      numChannels: numChannels,
      vectorSize: vectorSize,
    );
    final builder = BytesBuilder(copy: false);

    for (int i = 0; i < totalBlocks; i++) {
      final blockChannels = <Float32List>[
        for (int ch = 0; ch < numChannels; ch++)
          renderedBlocks[i * numChannels + ch],
      ];
      final byteView = switch (format) {
        .float32 => interleaver.interleaveFloat32Bytes(blockChannels),
        .pcm16 => interleaver.interleavePcm16Bytes(blockChannels),
      };
      builder.add(byteView);
    }

    final dataBytes = builder.takeBytes();
    final header = buildWavHeader(
      dataSize: dataBytes.length,
      sampleRate: sampleRate,
      numChannels: numChannels,
      format: format,
    );

    final wavFileBytes = BytesBuilder(copy: false);
    wavFileBytes.add(header.buffer.asUint8List(0, 44));
    wavFileBytes.add(dataBytes);
    final completeWav = wavFileBytes.takeBytes();

    if (path != null) {
      final file = File(path);
      await file.writeAsBytes(completeWav, flush: true);
    }

    return completeWav;
  }

  @override
  bool get isPlaying => _isPlaying;

  @override
  Future<void> startPlayback([AudioOutput? output]) async {
    if (_isDisposed) {
      throw StateError('Cannot startPlayback on a disposed AudioHost.');
    }
    if (_isPlaying) {
      throw StateError('Playback is already active.');
    }
    if (numChannels == 0) {
      throw StateError('No active audio graph to play. Call setGraph() first.');
    }
    if (output != null) {
      if (output.numChannels != numChannels) {
        throw ArgumentError(
          'Output numChannels (${output.numChannels}) does not match graph channels ($numChannels).',
        );
      }
      if (output.vectorSize != context.vectorSize) {
        throw ArgumentError(
          'Output vectorSize (${output.vectorSize}) does not match context vectorSize (${context.vectorSize}).',
        );
      }
    }

    _isPlaying = true;
    final audioReceivePort = _audioReceivePort = ReceivePort();
    audioReceivePort.listen((message) {
      if (message is List<Float32List>) {
        output?.write(message);
      }
    });

    _engineSendPort.send(StartPlaybackMessage(audioReceivePort.sendPort));
  }

  @override
  Future<void> stopPlayback() async {
    if (!_isPlaying) return;
    _isPlaying = false;
    final stopReplyPort = ReceivePort();
    _engineSendPort.send(StopPlaybackMessage(stopReplyPort.sendPort));
    await stopReplyPort.first;
    stopReplyPort.close();
    _audioReceivePort?.close();
    _audioReceivePort = null;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    if (_isPlaying) {
      await stopPlayback();
    }
    final replyPort = ReceivePort();
    _engineSendPort.send(DisposeMessage(replyPort.sendPort));
    await replyPort.first;
    replyPort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}
