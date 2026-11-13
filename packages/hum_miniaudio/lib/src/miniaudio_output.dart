import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:hum/hum.dart';

import 'bindings.dart';

/// Returns the version string of the bundled miniaudio native library.
String get miniaudioVersion => humMaVersionString().toDartString();

/// Hardware audio output descriptor backed by miniaudio and Dart Native Assets.
///
/// Contains only immutable, isolate-sendable configuration so it can be passed
/// directly to [AudioHost.startPlayback] on both `SyncAudioHost` and
/// `IsolateAudioHost`.
class const MiniaudioOutput({
  @override required final int numChannels,
  @override required final int vectorSize,
  final int? bufferFrames,
}) extends AudioOutput {
  this
    : assert(numChannels > 0, 'numChannels must be positive'),
      assert(vectorSize > 0, 'vectorSize must be positive'),
      assert(
        bufferFrames == null || bufferFrames >= vectorSize,
        'bufferFrames must be at least vectorSize',
      );

  @override
  bool get isIsolateSendable => true;

  @override
  AudioOutputDriver createDriver() => MiniaudioOutputDriver(
    numChannels: numChannels,
    vectorSize: vectorSize,
    bufferFrames: bufferFrames,
  );
}

/// Active driver managing a native miniaudio playback device and ring buffer.
class MiniaudioOutputDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
  final int? bufferFrames,
}) extends AudioOutputDriver {
  Pointer<HumMaPlayback> _handle = nullptr;
  Pointer<Float>? _interleaveBuffer;
  Float32List? _interleaveView;
  bool _isClosed = false;

  /// Number of float32 frames currently available to write without blocking.
  int get availableWriteFrames {
    final handle = _handle;
    if (_isClosed || handle == nullptr) return 0;
    return humMaPlaybackAvailableWrite(handle);
  }

  /// Whether the underlying audio device stopped unexpectedly.
  bool get isDeviceStopped {
    final handle = _handle;
    if (handle == nullptr) return false;
    return humMaPlaybackIsStopped(handle);
  }

  @override
  void start(ProcessContext context) {
    if (_isClosed) {
      throw StateError('MiniaudioOutputDriver has already been closed.');
    }
    if (_handle != nullptr) {
      throw StateError('MiniaudioOutputDriver has already been started.');
    }
    if (context.vectorSize != vectorSize) {
      throw ArgumentError.value(
        context.vectorSize,
        'context.vectorSize',
        'Must match driver vectorSize ($vectorSize)',
      );
    }

    final resolvedBufferFrames = bufferFrames ?? math.max(vectorSize * 4, 2048);
    final scratch = calloc<Float>(numChannels * vectorSize);
    final outHandle = calloc<Pointer<HumMaPlayback>>();

    try {
      final result = humMaPlaybackCreate(
        context.sampleRate,
        numChannels,
        resolvedBufferFrames,
        outHandle,
      );
      if (result != 0) {
        final description = humMaResultDescription(result).toDartString();
        throw StateError(
          'Failed to start miniaudio playback ($result): $description',
        );
      }

      _handle = outHandle.value;
      _interleaveBuffer = scratch;
      _interleaveView = scratch.asTypedList(numChannels * vectorSize);
    } catch (_) {
      calloc.free(scratch);
      rethrow;
    } finally {
      calloc.free(outHandle);
    }
  }

  @override
  PlaybackPacer createPacer(ProcessContext context) =>
      MiniaudioPlaybackPacer(driver: this, sampleRate: context.sampleRate);

  @override
  void write(List<Float32List> channels) {
    final handle = _handle;
    final scratch = _interleaveBuffer;
    final view = _interleaveView;
    if (_isClosed || handle == nullptr || scratch == null || view == null) {
      return;
    }

    if (humMaPlaybackIsStopped(handle)) {
      throw StateError('Audio playback device stopped unexpectedly.');
    }

    interleaveFloats(channels, view, vectorSize: vectorSize);
    humMaPlaybackWrite(handle, scratch, vectorSize);
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    if (_isClosed) return;
    _isClosed = true;

    final handle = _handle;
    _handle = nullptr;
    if (handle != nullptr) {
      humMaPlaybackClose(handle);
    }

    final scratch = _interleaveBuffer;
    _interleaveBuffer = nullptr;
    _interleaveView = null;
    if (scratch != null) {
      calloc.free(scratch);
    }
  }
}

/// Hardware-driven [PlaybackPacer] that paces DSP rendering to the miniaudio
/// ring buffer's available write capacity.
class MiniaudioPlaybackPacer({
  required final MiniaudioOutputDriver driver,
  required final int sampleRate,
}) extends PlaybackPacer {
  bool _stopped = false;
  Timer? _pendingTimer;
  Completer<void>? _pendingCompleter;

  @override
  void start() {
    _stopped = false;
  }

  @override
  FutureOr<void> waitForNextBlock() {
    if (_stopped) return null;
    if (driver.isDeviceStopped) {
      throw StateError('Audio playback device stopped unexpectedly.');
    }
    if (driver.availableWriteFrames >= driver.vectorSize) {
      return null;
    }
    return _waitForWriteSpace();
  }

  Future<void> _waitForWriteSpace() async {
    while (!_stopped) {
      if (driver.isDeviceStopped) {
        throw StateError('Audio playback device stopped unexpectedly.');
      }

      final available = driver.availableWriteFrames;
      if (available >= driver.vectorSize) {
        return;
      }

      final missingFrames = driver.vectorSize - available;
      final waitUs = math.max(1000, (missingFrames * 1000000) ~/ sampleRate);

      final completer = _pendingCompleter = Completer<void>();
      _pendingTimer = Timer(Duration(microseconds: waitUs), () {
        _pendingTimer = null;
        if (!completer.isCompleted) {
          _pendingCompleter = null;
          completer.complete();
        }
      });
      await completer.future;
    }
  }

  @override
  void stop() {
    _stopped = true;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    final completer = _pendingCompleter;
    _pendingCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}

