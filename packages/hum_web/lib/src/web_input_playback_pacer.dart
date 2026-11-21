import 'dart:async';

import 'package:hum/hum.dart';

/// An event-driven [PlaybackPacer] for input-only Web Audio capture sessions.
///
/// Returns synchronous `null` from [waitForNextBlock] whenever at least
/// [vectorSize] captured frames are already buffered. Otherwise suspends until
/// [onFramesAvailable] is invoked by the capture worklet's `MessagePort`.
class WebInputPlaybackPacer({
  required final int vectorSize,
  required final int Function() availableReadFrames,
  required final bool Function() isStopped,
}) extends PlaybackPacer {
  Completer<void>? _pendingCompleter;
  bool _stopped = false;

  this : assert(vectorSize > 0, 'vectorSize must be positive');

  @override
  void start() {
    _completePending();
    _stopped = false;
  }

  @override
  FutureOr<void> waitForNextBlock() {
    if (_stopped || isStopped()) return null;
    if (availableReadFrames() >= vectorSize) return null;

    final completer = _pendingCompleter = Completer<void>();
    return completer.future;
  }

  /// Notifies the pacer that new audio frames have arrived from the worklet.
  void onFramesAvailable() {
    if (_pendingCompleter == null) return;
    if (_stopped || isStopped() || availableReadFrames() >= vectorSize) {
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

  @override
  void stop() {
    _stopped = true;
    _completePending();
  }
}
