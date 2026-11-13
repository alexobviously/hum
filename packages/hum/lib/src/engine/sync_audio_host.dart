import 'dart:async';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Synchronous single-threaded implementation of [AudioHost].
class SyncAudioHost({
  @override required final ProcessContext context,
}) extends AudioHost {
  final AudioEngine _engine = AudioEngine(context: context);
  GraphSnapshot _currentSnapshot = .empty;
  bool _isPlaying = false;
  bool _isDisposed = false;
  int _playbackSession = 0;
  PlaybackPacer? _activePacer;
  Completer<void>? _playbackCompleter;

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
  bool get isPlaying => _isPlaying;

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
    final session = ++_playbackSession;
    final driver = output?.createDriver();
    final completer = _playbackCompleter = Completer<void>();
    _runPlaybackLoop(session, driver, completer);
  }

  void _runPlaybackLoop(
    int session,
    AudioOutputDriver? driver,
    Completer<void> completer,
  ) async {
    PlaybackPacer? pacer;
    try {
      if (driver != null) {
        final startResult = driver.start(context);
        if (startResult is Future<void>) {
          await startResult;
        }
        if (session != _playbackSession || !_isPlaying || _isDisposed) return;
      }

      pacer = _activePacer =
          driver?.createPacer(context) ??
          StopwatchPlaybackPacer(context: context);
      pacer.start();

      while (session == _playbackSession && _isPlaying && !_isDisposed) {
        final wait = pacer.waitForNextBlock();
        if (wait is Future<void>) {
          await wait;
          if (session != _playbackSession || !_isPlaying || _isDisposed) break;
        }

        _engine.process();
        driver?.write(_engine.outputs);
        pacer.onBlockProcessed();
      }
    } catch (e, st) {
      if (session == _playbackSession) {
        _isPlaying = false;
      }
      if (!completer.isCompleted) {
        completer.completeError(e, st);
      }
      return;
    } finally {
      pacer?.stop();
      if (identical(_activePacer, pacer)) {
        _activePacer = null;
      }
      if (session == _playbackSession) {
        _isPlaying = false;
      }
      if (driver != null) {
        try {
          await driver.close(waitForExit: !_isDisposed);
        } catch (_) {}
      }
      if (identical(_playbackCompleter, completer)) {
        _playbackCompleter = null;
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  @override
  Future<void> stopPlayback() async {
    if (!_isPlaying) return;
    _isPlaying = false;
    ++_playbackSession;
    _activePacer?.stop();
    final completer = _playbackCompleter;
    if (completer != null) {
      await completer.future;
    }
    if (identical(_playbackCompleter, completer)) {
      _playbackCompleter = null;
    }
  }

  /// Retrieves the active processor for [node], or null if not registered.
  T? processorOf<T extends AudioProcessor>(AudioNode node) {
    final id = _currentSnapshot.nodeIds[node];
    return id != null ? _engine.processorOf<T>(id) : null;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await stopPlayback();
    await _engine.dispose();
  }
}
