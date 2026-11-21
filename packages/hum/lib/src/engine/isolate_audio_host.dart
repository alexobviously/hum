import 'dart:async';
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

class const StartPlaybackMessage({
  required final int session,
  required final SendPort replyPort,
  final AudioOutput? workerOutput,
  final AudioInput? workerInput,
  final SendPort? audioDataPort,
}) extends HostToEngineMessage;

class const StopPlaybackMessage(final SendPort replyPort)
    extends HostToEngineMessage;

class const DisposeMessage([final SendPort? replyPort])
    extends HostToEngineMessage;

/// Messages sent from the background audio isolate to [IsolateAudioHost].
sealed class const EngineToHostMessage();

class const WorkerReadyMessage(final SendPort engineSendPort)
    extends EngineToHostMessage;

class const PlaybackErrorMessage({
  required final int session,
  required final Object error,
  final String? stackTrace,
}) extends EngineToHostMessage;

/// Top-level entrypoint for the background audio worker isolate.
void _audioWorkerEntry(
  ({SendPort hostSendPort, ProcessContext context}) args,
) {
  final workerReceivePort = ReceivePort();
  args.hostSendPort.send(WorkerReadyMessage(workerReceivePort.sendPort));

  final engine = AudioEngine(context: args.context);
  final context = args.context;

  bool isPlaying = false;
  bool isDisposed = false;
  // Mirrors the host's current playback session ID (0 when idle). Because
  // ReceivePort.listen runs an async callback that yields across driver.start(),
  // a Stop + Start pair can interleave while an earlier slow start() is pending;
  // checking this token prevents stale sessions from clobbering newer ones.
  int activeSession = 0;
  AudioOutputDriver? activeWorkerDriver;
  AudioInputDriver? activeWorkerInputDriver;
  // Drivers that have been created and not yet closed (or started closing).
  // Kept alongside closingDrivers so each driver is closed at most once even
  // when loop teardown, cancellation, and DisposeMessage overlap.
  final Set<AudioOutputDriver> openDrivers = {};
  final Set<AudioInputDriver> openInputDrivers = {};
  // Maps drivers whose async close() is currently in-flight to its completion
  // Future so DisposeMessage can await cleanup before killing the isolate.
  final Map<AudioOutputDriver, Future<void>> closingDrivers = {};
  final Map<AudioInputDriver, Future<void>> closingInputDrivers = {};
  PlaybackPacer? activePacer;
  SendPort? activeAudioPort;
  final Map<int, SendPort> pendingStartPorts = {};
  final Map<int, SendPort> pendingStopPorts = {};

  void completeStartWaiter([int? session]) {
    if (session != null) {
      pendingStartPorts.remove(session)?.send(null);
    } else if (pendingStartPorts.isNotEmpty) {
      for (final port in pendingStartPorts.values) {
        port.send(null);
      }
      pendingStartPorts.clear();
    }
  }

  // Raw thrown objects can capture unsendable state (ReceivePorts, closures,
  // FFI pointers). Attempt to send the original object, falling back to its
  // string form so reporting an error never crashes the worker isolate itself.
  void safeSendError(
    void Function(Object error, String stackTrace) send,
    Object error,
    StackTrace stackTrace,
  ) {
    final stackString = stackTrace.toString();
    try {
      send(error, stackString);
    } catch (_) {
      send(error.toString(), stackString);
    }
  }

  void completeStartError(int session, Object error, StackTrace stackTrace) {
    final port = pendingStartPorts.remove(session);
    if (port == null) return;
    safeSendError(
      (err, stack) => port.send((error: err, stackTrace: stack)),
      error,
      stackTrace,
    );
  }

  void reportPlaybackError(int session, Object error, StackTrace stackTrace) {
    safeSendError(
      (err, stack) => args.hostSendPort.send(
        PlaybackErrorMessage(session: session, error: err, stackTrace: stack),
      ),
      error,
      stackTrace,
    );
  }

  Future<void> closeDriverOnce(
    AudioOutputDriver? driver, {
    required bool waitForExit,
  }) async {
    if (driver == null) return;

    if (identical(activeWorkerDriver, driver)) {
      activeWorkerDriver = null;
    }

    final existingClose = closingDrivers[driver];
    if (existingClose != null) {
      await existingClose;
      return;
    }

    if (!openDrivers.remove(driver)) return;

    final completer = Completer<void>();

    closingDrivers[driver] = completer.future;
    try {
      await driver.close(waitForExit: waitForExit);
    } catch (_) {
    } finally {
      unawaited(closingDrivers.remove(driver));
      completer.complete();
    }
  }

  Future<void> closeInputDriverOnce(
    AudioInputDriver? driver, {
    required bool waitForExit,
  }) async {
    if (driver == null) return;

    if (identical(activeWorkerInputDriver, driver)) {
      activeWorkerInputDriver = null;
    }

    final existingClose = closingInputDrivers[driver];
    if (existingClose != null) {
      await existingClose;
      return;
    }

    if (!openInputDrivers.remove(driver)) return;

    final completer = Completer<void>();

    closingInputDrivers[driver] = completer.future;
    try {
      await driver.close(waitForExit: waitForExit);
    } catch (_) {
    } finally {
      unawaited(closingInputDrivers.remove(driver));
      completer.complete();
    }
  }

  void completeStopWaiters([int? session]) {
    if (session != null) {
      pendingStopPorts.remove(session)?.send(null);
    } else if (pendingStopPorts.isNotEmpty) {
      for (final port in pendingStopPorts.values) {
        port.send(null);
      }
      pendingStopPorts.clear();
    }
  }

  void runPlaybackLoop(
    int session,
    AudioOutputDriver? driver,
    AudioInputDriver? inputDriver,
    PlaybackPacer pacer,
  ) async {
    Object? loopError;
    StackTrace? loopStack;
    pacer.start();

    try {
      while (session == activeSession && isPlaying && !isDisposed) {
        final wait = pacer.waitForNextBlock();
        if (wait is Future<void>) {
          await wait;
          if (session != activeSession || !isPlaying || isDisposed) break;
        }

        inputDriver?.read(engine.inputs);
        engine.process();

        if (driver != null) {
          driver.write(engine.outputs);
        } else if (activeAudioPort != null) {
          final numChannels = engine.numChannels;
          final channelCopies = <Float32List>[
            for (int ch = 0; ch < numChannels; ch++)
              .fromList(engine.outputs[ch]),
          ];
          activeAudioPort!.send(channelCopies);
        }
        pacer.onBlockProcessed();
      }
    } catch (e, st) {
      loopError = e;
      loopStack = st;
    } finally {
      pacer.stop();
      if (identical(activePacer, pacer)) {
        activePacer = null;
      }

      if (session == activeSession) {
        activeSession = 0;
        isPlaying = false;
        activeAudioPort = null;
        engine.configureInputs(0);
      }
      await closeDriverOnce(driver, waitForExit: !isDisposed);
      await closeInputDriverOnce(inputDriver, waitForExit: !isDisposed);
      // Report mid-playback errors only after clearing session state and
      // closing the driver so a playbackErrors listener can restart safely.
      if (loopError != null && !isDisposed) {
        reportPlaybackError(session, loopError, loopStack!);
      }
      completeStopWaiters(session);
    }
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
      case StartPlaybackMessage(
        :final session,
        :final replyPort,
        :final workerOutput,
        :final workerInput,
        :final audioDataPort,
      ):
        if (isPlaying || isDisposed) {
          replyPort.send(null);
          return;
        }
        isPlaying = true;
        activeSession = session;
        pendingStartPorts[session] = replyPort;
        activeAudioPort = audioDataPort;
        final inputDriver = workerInput?.createDriver();
        final driver = workerOutput?.createDriver();
        if (inputDriver != null) {
          openInputDrivers.add(inputDriver);
          activeWorkerInputDriver = inputDriver;
        }
        if (driver != null) {
          openDrivers.add(driver);
          activeWorkerDriver = driver;
        }
        if (inputDriver != null || driver != null) {
          try {
            if (inputDriver != null) {
              final startResult = inputDriver.start(context);
              if (startResult is Future<void>) {
                await startResult;
              }
            }
            if (driver != null) {
              final startResult = driver.start(context);
              if (startResult is Future<void>) {
                await startResult;
              }
            }
          } catch (e, st) {
            await closeDriverOnce(driver, waitForExit: false);
            await closeInputDriverOnce(inputDriver, waitForExit: false);
            if (session == activeSession) {
              activeSession = 0;
              isPlaying = false;
              activeAudioPort = null;
              engine.configureInputs(0);
            }
            completeStartError(session, e, st);
            completeStopWaiters(session);
            return;
          }
          if (session != activeSession || !isPlaying || isDisposed) {
            await closeDriverOnce(driver, waitForExit: !isDisposed);
            await closeInputDriverOnce(inputDriver, waitForExit: !isDisposed);
            completeStartWaiter(session);
            completeStopWaiters(session);
            return;
          }
        }
        if (session != activeSession || !isPlaying || isDisposed) {
          await closeDriverOnce(driver, waitForExit: !isDisposed);
          await closeInputDriverOnce(inputDriver, waitForExit: !isDisposed);
          completeStartWaiter(session);
          completeStopWaiters(session);
          return;
        }
        engine.configureInputs(inputDriver?.numChannels ?? 0);
        final pacer = activePacer =
            driver?.createPacer(context) ??
            inputDriver?.createPacer(context) ??
            StopwatchPlaybackPacer(context: context);
        completeStartWaiter(session);
        runPlaybackLoop(session, driver, inputDriver, pacer);
      case StopPlaybackMessage(:final replyPort):
        if (isPlaying) {
          final stoppedSession = activeSession;
          activeSession = 0;
          isPlaying = false;
          pendingStopPorts[stoppedSession] = replyPort;
          activePacer?.stop();
        } else {
          replyPort.send(null);
        }
      case DisposeMessage(:final replyPort):
        isDisposed = true;
        isPlaying = false;
        activeSession = 0;
        activePacer?.stop();
        await closeDriverOnce(activeWorkerDriver, waitForExit: false);
        await closeInputDriverOnce(activeWorkerInputDriver, waitForExit: false);
        for (final driver in openDrivers.toList()) {
          await closeDriverOnce(driver, waitForExit: false);
        }
        for (final inputDriver in openInputDrivers.toList()) {
          await closeInputDriverOnce(inputDriver, waitForExit: false);
        }
        // Wait for any already-in-flight close() started by loop/stop teardown
        // so the host does not kill the isolate before driver cleanup finishes.
        if (closingDrivers.isNotEmpty) {
          await Future.wait(closingDrivers.values.toList());
        }
        if (closingInputDrivers.isNotEmpty) {
          await Future.wait(closingInputDrivers.values.toList());
        }
        // Resolve every outstanding start/stop handshake so callers awaiting
        // them never hang if dispose() interrupts an in-flight transition.
        completeStartWaiter();
        completeStopWaiters();
        await engine.dispose();
        replyPort?.send(null);
        workerReceivePort.close();
    }
  });
}

/// Multi-threaded isolate implementation of [AudioHost].
class IsolateAudioHost._({
  @override required final ProcessContext context,
  required this._isolate,
  required this._engineSendPort,
  required this._hostReceivePort,
  required this._hostPortSub,
}) extends AudioHost {
  final Isolate _isolate;
  final SendPort _engineSendPort;
  final ReceivePort _hostReceivePort;
  final StreamSubscription<Object?> _hostPortSub;
  final StreamController<AudioPlaybackError> _errorController =
      StreamController<AudioPlaybackError>.broadcast();
  GraphSnapshot _currentSnapshot = .empty;
  bool _isDisposed = false;
  bool _isPlaying = false;
  int _playbackSession = 0;
  ReceivePort? _audioReceivePort;
  AudioOutputDriver? _hostOutputDriver;

  /// Spawns a new background worker isolate running [AudioEngine].
  static Future<IsolateAudioHost> spawn({
    required ProcessContext context,
  }) async {
    final hostReceivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _audioWorkerEntry,
      (hostSendPort: hostReceivePort.sendPort, context: context),
      debugName: 'hum_engine',
    );

    final readyCompleter = Completer<SendPort>();
    late final IsolateAudioHost host;
    // Subscription is cancelled in `dispose()`
    // ignore: cancel_subscriptions
    late final StreamSubscription<Object?> hostPortSub;
    hostPortSub = hostReceivePort.listen((message) {
      switch (message) {
        case WorkerReadyMessage(:final engineSendPort):
          if (!readyCompleter.isCompleted) {
            readyCompleter.complete(engineSendPort);
          }
        case PlaybackErrorMessage(
          :final session,
          :final error,
          :final stackTrace,
        ):
          host._handleWorkerPlaybackError(session, error, stackTrace);
      }
    });

    final engineSendPort = await readyCompleter.future;
    host = IsolateAudioHost._(
      context: context,
      isolate: isolate,
      engineSendPort: engineSendPort,
      hostReceivePort: hostReceivePort,
      hostPortSub: hostPortSub,
    );
    return host;
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
  bool get isPlaying => _isPlaying;

  @override
  Stream<AudioPlaybackError> get playbackErrors => _errorController.stream;

  void _handleWorkerPlaybackError(
    int session,
    Object error,
    String? stackTrace,
  ) {
    if (_isDisposed) return;
    // Sync host state when the active session dies unexpectedly on the worker.
    if (session == _playbackSession && _isPlaying) {
      _isPlaying = false;
      _audioReceivePort?.close();
      _audioReceivePort = null;
      unawaited(_closeHostDriver(waitForExit: false));
    }
    if (!_errorController.isClosed) {
      _errorController.add(
        AudioPlaybackError(
          error: error,
          stackTrace: stackTrace != null
              ? StackTrace.fromString(stackTrace)
              : null,
        ),
      );
    }
  }

  @override
  Future<void> startPlayback({AudioOutput? output, AudioInput? input}) async {
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
      if (!input.isIsolateSendable) {
        throw ArgumentError(
          'IsolateAudioHost requires an isolate-sendable AudioInput.',
        );
      }
    }

    _isPlaying = true;
    final session = ++_playbackSession;
    final startReplyPort = ReceivePort();

    if (output == null || output.isIsolateSendable) {
      _engineSendPort.send(
        StartPlaybackMessage(
          session: session,
          replyPort: startReplyPort.sendPort,
          workerOutput: output,
          workerInput: input,
        ),
      );
      final reply = await startReplyPort.first;
      startReplyPort.close();
      if (reply is ({Object error, String? stackTrace})) {
        if (session == _playbackSession) {
          _isPlaying = false;
        }
        Error.throwWithStackTrace(
          reply.error,
          StackTrace.fromString(reply.stackTrace ?? ''),
        );
      }
      return;
    }

    final driver = output.createDriver();
    try {
      final startResult = driver.start(context);
      if (startResult is Future<void>) {
        await startResult;
      }
    } catch (_) {
      startReplyPort.close();
      if (session == _playbackSession) {
        _isPlaying = false;
      }
      try {
        await driver.close(waitForExit: false);
      } catch (_) {}
      rethrow;
    }
    if (session != _playbackSession || !_isPlaying || _isDisposed) {
      startReplyPort.close();
      try {
        await driver.close(waitForExit: !_isDisposed);
      } catch (_) {}
      return;
    }

    _hostOutputDriver = driver;
    final audioReceivePort = _audioReceivePort = ReceivePort();
    audioReceivePort.listen((message) {
      if (message is List<Float32List>) {
        try {
          driver.write(message);
        } catch (e, st) {
          if (session == _playbackSession && _isPlaying && !_isDisposed) {
            unawaited(stopPlayback());
            if (!_errorController.isClosed) {
              _errorController.add(
                AudioPlaybackError(error: e, stackTrace: st),
              );
            }
          }
        }
      }
    });
    _engineSendPort.send(
      StartPlaybackMessage(
        session: session,
        replyPort: startReplyPort.sendPort,
        workerInput: input,
        audioDataPort: audioReceivePort.sendPort,
      ),
    );
    final reply = await startReplyPort.first;
    startReplyPort.close();
    if (reply is ({Object error, String? stackTrace})) {
      if (session == _playbackSession) {
        _isPlaying = false;
      }
      if (identical(_audioReceivePort, audioReceivePort)) {
        _audioReceivePort = null;
      }
      audioReceivePort.close();
      if (identical(_hostOutputDriver, driver)) {
        _hostOutputDriver = null;
      }
      try {
        await driver.close(waitForExit: false);
      } catch (_) {}
      Error.throwWithStackTrace(
        reply.error,
        StackTrace.fromString(reply.stackTrace ?? ''),
      );
    }
    // Clean up only this session's resources if stopPlayback/dispose landed
    // while waiting on the worker handshake, leaving newer sessions untouched.
    if (session != _playbackSession || !_isPlaying || _isDisposed) {
      if (identical(_audioReceivePort, audioReceivePort)) {
        _audioReceivePort = null;
      }
      audioReceivePort.close();
      if (identical(_hostOutputDriver, driver)) {
        _hostOutputDriver = null;
      }
      try {
        await driver.close(waitForExit: !_isDisposed);
      } catch (_) {}
    }
  }

  Future<void> _closeHostDriver({required bool waitForExit}) async {
    // Detach before awaiting close() so stopPlayback() and dispose() cannot
    // double-close the same host-bound driver concurrently.
    final hostDriver = _hostOutputDriver;
    _hostOutputDriver = null;
    if (hostDriver != null) {
      try {
        await hostDriver.close(waitForExit: waitForExit);
      } catch (_) {}
    }
  }

  @override
  Future<void> stopPlayback() async {
    if (!_isPlaying) return;
    _isPlaying = false;
    ++_playbackSession;
    final stopReplyPort = ReceivePort();
    _engineSendPort.send(StopPlaybackMessage(stopReplyPort.sendPort));
    await stopReplyPort.first;
    stopReplyPort.close();
    _audioReceivePort?.close();
    _audioReceivePort = null;
    await _closeHostDriver(waitForExit: true);
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    ++_playbackSession;
    if (_isPlaying) {
      await stopPlayback();
    }
    final replyPort = ReceivePort();
    _engineSendPort.send(DisposeMessage(replyPort.sendPort));
    await replyPort.first;
    replyPort.close();
    _audioReceivePort?.close();
    _audioReceivePort = null;
    await _closeHostDriver(waitForExit: false);
    await _hostPortSub.cancel();
    _hostReceivePort.close();
    await _errorController.close();
    _isolate.kill();
  }
}
