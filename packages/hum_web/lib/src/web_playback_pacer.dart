import 'dart:async';

import 'package:hum/hum.dart';

/// An event-driven backpressure [PlaybackPacer] for Web Audio `AudioWorklet`
/// playback.
///
/// Tracks the number of audio frames currently queued/in-flight to the worklet
/// ring buffer. Returns synchronous `null` from [waitForNextBlock] while the
/// buffer has space for at least one [vectorSize] block, avoiding per-block
/// [Future] allocations on hot paths. When full, suspends until
/// [onFramesConsumed] reports drained space from the worklet's `MessagePort`.
class WebPlaybackPacer({
  required final int vectorSize,
  required final int bufferFrames,
  required final bool Function() isStopped,
}) extends PlaybackPacer {
  int _queuedFrames = 0;
  Completer<void>? _pendingCompleter;
  bool _stopped = false;

  this
    : assert(vectorSize > 0, 'vectorSize must be positive'),
      assert(
        bufferFrames >= vectorSize,
        'bufferFrames must be at least vectorSize',
      );

  /// Frames currently queued or in-flight to the worklet ring buffer.
  int get queuedFrames => _queuedFrames;

  /// Estimated free frame capacity remaining before backpressure engages.
  int get availableWriteFrames {
    final free = bufferFrames - _queuedFrames;
    return free > 0 ? free : 0;
  }

  @override
  void start() {
    _cancelPending();
    _queuedFrames = 0;
    _stopped = false;
  }

  @override
  FutureOr<void> waitForNextBlock() {
    if (_stopped || isStopped()) return null;
    if (_queuedFrames + vectorSize <= bufferFrames) return null;

    final completer = _pendingCompleter = Completer<void>();
    return completer.future;
  }

  @override
  void onBlockProcessed() {
    _queuedFrames += vectorSize;
  }

  /// Reports that the `AudioWorklet` has consumed [frames] from its ring buffer.
  ///
  /// Immediately wakes any pending [waitForNextBlock] call once enough capacity
  /// is free for the next [vectorSize] block.
  void onFramesConsumed(int frames) {
    if (frames <= 0) return;
    _queuedFrames -= frames;
    if (_queuedFrames < 0) {
      _queuedFrames = 0;
    }

    if (_queuedFrames + vectorSize <= bufferFrames) {
      _completePending();
    }
  }

  void _completePending() {
    final completer = _pendingCompleter;
    _pendingCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _cancelPending() {
    _completePending();
  }

  @override
  void stop() {
    _stopped = true;
    _cancelPending();
  }
}
