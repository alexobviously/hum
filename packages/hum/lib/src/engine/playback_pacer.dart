import 'dart:async';

import 'package:hum/hum.dart';

/// Controls block-by-block timing and backpressure during real-time playback.
///
/// Hosts call [start] before entering the playback loop, [waitForNextBlock]
/// before rendering each block, [onBlockProcessed] after writing a block, and
/// [stop] to release resources and unblock any pending wait immediately.
abstract class const PlaybackPacer() {
  /// Resets pacing state for a new playback session.
  void start();

  /// Waits until the engine should render and push the next block.
  ///
  /// Returning synchronous `null` (as `FutureOr<void>`) when the consumer
  /// already has capacity avoids per-block [Future] allocations on hot paths.
  FutureOr<void> waitForNextBlock();

  /// Notifies the pacer that one block has been rendered and written.
  void onBlockProcessed() {}

  /// Stops pacing and immediately wakes any pending [waitForNextBlock] call.
  void stop();
}

/// Default wall-clock [PlaybackPacer] backed by a monotonic [Stopwatch].
///
/// Used for outputs without intrinsic hardware backpressure (such as
/// `PipedAudioOutput`, `MemoryAudioOutput`, `NullAudioOutput`, or headless
/// `startPlayback()` with no output).
class StopwatchPlaybackPacer({
  required final ProcessContext context,
  final int minLeadUs = 25000,
}) extends PlaybackPacer {
  final Stopwatch _stopwatch = Stopwatch();
  int _renderedSamples = 0;
  Timer? _pendingTimer;
  Completer<void>? _pendingCompleter;
  bool _stopped = false;

  late final int _blockDurationUs =
      (context.vectorSize * 1000000) ~/ context.sampleRate;
  late final int _targetLeadUs = _blockDurationUs * 2 > minLeadUs
      ? _blockDurationUs * 2
      : minLeadUs;

  @override
  void start() {
    _stopped = false;
    _renderedSamples = 0;
    _stopwatch
      ..reset()
      ..start();
  }

  @override
  FutureOr<void> waitForNextBlock() {
    if (_stopped) return null;

    final sampleRate = context.sampleRate;
    final renderedTimeUs = (_renderedSamples * 1000000) ~/ sampleRate;
    final elapsedUs = _stopwatch.elapsedMicroseconds;

    // Prevent burst rendering if clock desynchronizes (e.g. system sleep)
    if (elapsedUs - renderedTimeUs > 100000) {
      _renderedSamples = (elapsedUs * sampleRate) ~/ 1000000;
    }

    final leadUs = ((_renderedSamples * 1000000) ~/ sampleRate) - elapsedUs;
    if (leadUs <= _targetLeadUs) return null;

    final sleepUs = leadUs - _targetLeadUs;
    if (sleepUs < 1000) {
      return Future<void>.delayed(Duration.zero);
    }

    final completer = _pendingCompleter = Completer<void>();
    _pendingTimer = Timer(Duration(microseconds: sleepUs), () {
      _pendingTimer = null;
      _pendingCompleter = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  @override
  void onBlockProcessed() {
    _renderedSamples += context.vectorSize;
  }

  @override
  void stop() {
    _stopped = true;
    _stopwatch.stop();
    _pendingTimer?.cancel();
    _pendingTimer = null;
    final completer = _pendingCompleter;
    _pendingCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}
