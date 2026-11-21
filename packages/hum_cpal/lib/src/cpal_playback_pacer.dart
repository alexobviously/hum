import 'dart:async';

import 'package:hum/hum.dart';

/// A hardware-clocked [PlaybackPacer] driven by the ready frame count in a
/// Rust `cpal` `rtrb` ring buffer.
///
/// Used by both `CpalAudioOutputDriver` (polling free write frames) and
/// `CpalAudioInputDriver` (polling buffered read frames), since Rust owns the
/// lock-free `rtrb` ring buffer in both directions.
///
/// Returns synchronous `null` from [waitForNextBlock] whenever at least
/// [vectorSize] frames are ready immediately without blocking, avoiding
/// per-block [Future] allocations on hot paths.
class CpalPlaybackPacer({
  required final int sampleRate,
  required final int vectorSize,
  required final int Function() availableFrames,
  required final bool Function() isStopped,

  /// Minimum time in microseconds to wait between polls.
  final int minPollUs = 1000,
}) extends PlaybackPacer {
  Timer? _pendingTimer;
  Completer<void>? _pendingCompleter;
  bool _stopped = false;

  this
    : assert(sampleRate > 0, 'sampleRate must be positive'),
      assert(vectorSize > 0, 'vectorSize must be positive'),
      assert(minPollUs > 0, 'minPollUs must be positive');

  @override
  void start() {
    _cancelPending();
    _stopped = false;
  }

  @override
  FutureOr<void> waitForNextBlock() {
    if (_stopped || isStopped()) return null;

    final available = availableFrames();
    if (available >= vectorSize) return null;

    final completer = _pendingCompleter = Completer<void>();
    _schedulePoll(vectorSize - available, completer);
    return completer.future;
  }

  void _schedulePoll(int neededFrames, Completer<void> completer) {
    // This code is monke cos we are still in the audio isolate here!
    int sleepUs = (neededFrames * 1000000) ~/ sampleRate;
    if (sleepUs < minPollUs) {
      sleepUs = minPollUs;
    }

    _pendingTimer = Timer(Duration(microseconds: sleepUs), () {
      _pendingTimer = null;
      if (_stopped || !identical(_pendingCompleter, completer)) {
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }

      if (isStopped()) {
        _pendingCompleter = null;
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }

      final available = availableFrames();
      if (available >= vectorSize) {
        _pendingCompleter = null;
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }

      _schedulePoll(vectorSize - available, completer);
    });
  }

  void _cancelPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    final completer = _pendingCompleter;
    _pendingCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  @override
  void stop() {
    _stopped = true;
    _cancelPending();
  }
}

// The `Timer`s, `Completer`s and `Future`s here do allocate to the heap.
// I don't think there's a real way to avoid this and it's probably
// inconsequential, but worth a note.
