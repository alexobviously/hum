import 'dart:async';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Synchronous single-threaded implementation of [AudioHost].
class SyncAudioHost({
  @override required final ProcessContext context,
  final Duration telemetryInterval = const Duration(milliseconds: 20),
}) extends AudioHost {
  final TelemetryRegistry _telemetry = TelemetryRegistry();
  late final AudioEngine _engine = AudioEngine(
    context: context,
    telemetryInterval: telemetryInterval,
    onTelemetry: _telemetry.dispatch,
  );
  GraphSnapshot _currentSnapshot = .empty;
  int _nextBufferId = 1;
  bool _isPlaying = false;
  bool _isDisposed = false;
  int _playbackSession = 0;
  PlaybackPacer? _activePacer;
  Completer<void>? _playbackCompleter;
  final StreamController<AudioPlaybackError> _errorController =
      StreamController<AudioPlaybackError>.broadcast();

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
  Stream<AudioPlaybackError> get playbackErrors => _errorController.stream;

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
    _telemetry.onGraphDiff(diff);
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

  @override
  TelemetryChannel<T>? telemetryOf<T>(TelemetryNode<T> node) =>
      _telemetry.channelFor(_currentSnapshot, node);

  @override
  BufferHandle loadBuffer(AudioBuffer buffer) {
    if (_isDisposed) {
      throw StateError('Cannot loadBuffer on a disposed AudioHost.');
    }
    final id = BufferId(_nextBufferId++);
    _engine.loadBuffer(id, buffer);
    return BufferHandle(
      id: id,
      sampleRate: buffer.sampleRate,
      numChannels: buffer.numChannels,
      length: buffer.length,
    );
  }

  @override
  void unloadBuffer(BufferHandle handle) {
    if (_isDisposed) return;
    _engine.unloadBuffer(handle.id);
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
  Future<void> startPlayback({
    AudioOutput? output,
    AudioInput? input,
    bool safetyGuard = true,
  }) async {
    if (_isDisposed) {
      throw StateError('Cannot startPlayback on a disposed AudioHost.');
    }
    if (_isPlaying) {
      throw StateError('Playback is already active.');
    }
    if (_currentSnapshot.isEmpty) {
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
    if (input != null) {
      if (input.vectorSize != context.vectorSize) {
        throw ArgumentError(
          'Input vectorSize (${input.vectorSize}) does not match context vectorSize (${context.vectorSize}).',
        );
      }
    }

    _isPlaying = true;
    // Monotonic session token so a fast stop -> start sequence never lets an
    // interrupted async driver.start() tear down or steal the newer session.
    final session = ++_playbackSession;
    final outputDriver = output?.createDriver();
    final inputDriver = input?.createDriver();
    final completer = _playbackCompleter = Completer<void>();

    if (inputDriver != null || outputDriver != null) {
      try {
        if (inputDriver != null) {
          final startResult = inputDriver.start(context);
          if (startResult is Future<void>) {
            await startResult;
          }
        }
        if (outputDriver != null) {
          final startResult = outputDriver.start(context);
          if (startResult is Future<void>) {
            await startResult;
          }
        }
      } catch (_) {
        if (session == _playbackSession) {
          _isPlaying = false;
        }
        if (outputDriver != null) {
          try {
            await outputDriver.close(waitForExit: false);
          } catch (_) {}
        }
        if (inputDriver != null) {
          try {
            await inputDriver.close(waitForExit: false);
          } catch (_) {}
        }
        if (identical(_playbackCompleter, completer)) {
          _playbackCompleter = null;
        }
        // Unblock any concurrent stopPlayback() awaiting this session before rethrowing.
        if (!completer.isCompleted) {
          completer.complete();
        }
        rethrow;
      }

      // StopPlayback or dispose ran while awaiting driver.start().
      if (session != _playbackSession || !_isPlaying || _isDisposed) {
        if (outputDriver != null) {
          try {
            await outputDriver.close(waitForExit: !_isDisposed);
          } catch (_) {}
        }
        if (inputDriver != null) {
          try {
            await inputDriver.close(waitForExit: !_isDisposed);
          } catch (_) {}
        }
        if (identical(_playbackCompleter, completer)) {
          _playbackCompleter = null;
        }
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }
    }

    _engine.configureInputs(inputDriver?.numChannels ?? 0);
    _runPlaybackLoop(session, outputDriver, inputDriver, safetyGuard, completer);
  }

  void _runPlaybackLoop(
    int session,
    AudioOutputDriver? outputDriver,
    AudioInputDriver? inputDriver,
    bool safetyGuard,
    Completer<void> completer,
  ) async {
    final pacer = _activePacer =
        outputDriver?.createPacer(context) ??
        inputDriver?.createPacer(context) ??
        StopwatchPlaybackPacer(context: context);
    pacer.start();
    try {
      while (session == _playbackSession && _isPlaying && !_isDisposed) {
        final wait = pacer.waitForNextBlock();
        if (wait is Future<void>) {
          await wait;
          if (session != _playbackSession || !_isPlaying || _isDisposed) break;
        }

        inputDriver?.read(_engine.inputs);
        _engine.process();
        if (outputDriver != null) {
          if (safetyGuard) {
            sanitizeAudioOutputs(_engine.outputs, context.vectorSize);
          }
          outputDriver.write(_engine.outputs);
        }
        pacer.onBlockProcessed();
      }
    } catch (e, st) {
      // Mid-loop failures cannot be thrown back from startPlayback() (it has
      // already returned), so surface them on playbackErrors instead.
      if (!_errorController.isClosed) {
        _errorController.add(AudioPlaybackError(error: e, stackTrace: st));
      }
    } finally {
      pacer.stop();
      if (identical(_activePacer, pacer)) {
        _activePacer = null;
      }
      if (session == _playbackSession) {
        _isPlaying = false;
        _engine.configureInputs(0);
      }
      if (outputDriver != null) {
        // Ignore close() exceptions so _playbackCompleter always resolves and
        // stopPlayback() never hangs waiting on a broken driver.
        try {
          await outputDriver.close(waitForExit: !_isDisposed);
        } catch (_) {}
      }
      if (inputDriver != null) {
        try {
          await inputDriver.close(waitForExit: !_isDisposed);
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
    await _telemetry.dispose();
    await _errorController.close();
  }
}
