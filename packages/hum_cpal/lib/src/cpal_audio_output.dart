import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:hum/hum.dart';

import 'cpal_bindings.dart';
import 'cpal_playback_pacer.dart';

/// Immutable, isolate-sendable configuration descriptor for an [AudioOutput]
/// that streams audio to a native `cpal` hardware playback device.
///
/// Selecting `deviceId == null` opens the host's default output device.
class const CpalAudioOutput({
  @override required final int numChannels,
  @override required final int vectorSize,
  final String? deviceId,
  final int bufferFrames = 2048,
}) extends AudioOutput {
  this
    : assert(numChannels > 0, 'numChannels must be positive'),
      assert(vectorSize > 0, 'vectorSize must be positive'),
      assert(
        bufferFrames >= vectorSize,
        'bufferFrames must be at least vectorSize',
      );

  @override
  bool get isIsolateSendable => true;

  @override
  AudioOutputDriver createDriver() => CpalAudioOutputDriver(
    numChannels: numChannels,
    vectorSize: vectorSize,
    deviceId: deviceId,
    bufferFrames: bufferFrames,
  );
}

/// Runtime driver created by [CpalAudioOutput.createDriver].
///
/// Owns the native [HumPlaybackHandle], a persistent interleaved [Float32List]
/// staging buffer over native memory, and hardware backpressure pacing via
/// [CpalPlaybackPacer].
class CpalAudioOutputDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
  final String? deviceId,
  final int bufferFrames = 2048,
}) extends AudioOutputDriver {
  Pointer<HumPlaybackHandle> _handle = nullptr;
  Pointer<Float> _nativeBuffer = nullptr;
  Float32List? _nativeView;
  bool _isClosed = false;

  /// Whether the native `cpal` stream handle is currently open.
  bool get isOpen => _handle != nullptr;

  /// Whether [close] has been called on this driver.
  bool get isClosed => _isClosed;

  /// Whether the stream has stopped due to a hardware error or is closed.
  bool get isStopped => _handle == nullptr || humCpalPlaybackIsStopped(_handle);

  /// Interleaved frames currently free to write in the ring buffer.
  int get availableWriteFrames =>
      _handle == nullptr ? 0 : humCpalPlaybackAvailableWrite(_handle);

  /// Hardware callback underrun count observed since [start].
  int get underruns =>
      _handle == nullptr ? 0 : humCpalPlaybackUnderruns(_handle);

  // TODO: consider result-based error handling instead of exceptions
  @override
  void start(ProcessContext context) {
    if (_isClosed) {
      throw StateError('CpalAudioOutputDriver has been closed.');
    }
    if (_handle != nullptr) return;

    if (context.vectorSize != vectorSize) {
      throw ArgumentError.value(
        context.vectorSize,
        'context.vectorSize',
        'Expected vectorSize $vectorSize',
      );
    }
    if (bufferFrames < vectorSize) {
      throw ArgumentError.value(
        bufferFrames,
        'bufferFrames',
        'Must be at least vectorSize ($vectorSize)',
      );
    }

    final outError = calloc<Pointer<Utf8>>();
    final deviceIdPtr = deviceId?.toNativeUtf8() ?? nullptr;

    Pointer<HumPlaybackHandle> handle = nullptr;
    try {
      handle = humCpalPlaybackCreate(
        deviceIdPtr,
        context.sampleRate,
        numChannels,
        bufferFrames,
        outError,
      );

      if (handle == nullptr) {
        final errPtr = outError.value;

        final String message;
        if (errPtr != nullptr) {
          // Use error from rust side if there is one.
          message = errPtr.toDartString();
          humCpalFreeString(errPtr);
        } else {
          message = 'Failed to create cpal playback stream.';
        }

        throw StateError(message);
      }

      final totalSamples = numChannels * vectorSize;
      final nativeBuffer = calloc<Float>(totalSamples);
      _nativeBuffer = nativeBuffer;
      _nativeView = nativeBuffer.asTypedList(totalSamples);
      _handle = handle;
      handle = nullptr;
    } finally {
      if (handle != nullptr) {
        humCpalPlaybackClose(handle);
      }
      // Never thought I'd have to do this in dart but here we are!
      if (deviceIdPtr != nullptr) {
        calloc.free(deviceIdPtr);
      }
      calloc.free(outError);
    }
  }

  @override
  PlaybackPacer createPacer(ProcessContext context) {
    if (_handle == nullptr) {
      throw StateError(
        'Cannot create a pacer before CpalAudioOutputDriver.start().',
      );
    }

    return CpalPlaybackPacer(
      sampleRate: context.sampleRate,
      vectorSize: vectorSize,
      availableFrames: () => availableWriteFrames,
      isStopped: () => _isClosed || isStopped,
    );
  }

  @override
  void write(List<Float32List> channels) {
    final handle = _handle;
    if (_isClosed || handle == nullptr) return;

    if (humCpalPlaybackIsStopped(handle)) {
      _throwStreamError(handle);
    }

    interleaveFloats(channels, _nativeView!, vectorSize: vectorSize);
    final written = humCpalPlaybackWrite(handle, _nativeBuffer, vectorSize);
    if (written < vectorSize && humCpalPlaybackIsStopped(handle)) {
      _throwStreamError(handle);
    }
  }

  Never _throwStreamError(Pointer<HumPlaybackHandle> handle) {
    final errPtr = humCpalPlaybackTakeError(handle);

    final String message;
    if (errPtr != nullptr) {
      message = errPtr.toDartString();
      humCpalFreeString(errPtr);
    } else {
      message = 'cpal playback stream stopped unexpectedly.';
    }

    throw StateError(message);
  }

  // TODO: use NativeFinalizer to ensure pointers get freed if someone forgets to close() this
  // ^ check cpal's thread drop behaviour when doing this

  @override
  Future<void> close({bool waitForExit = true}) async {
    if (_isClosed) return;
    _isClosed = true;

    final handle = _handle;
    final nativeBuffer = _nativeBuffer;
    _handle = nullptr;
    _nativeBuffer = nullptr;
    _nativeView = null;

    humCpalPlaybackClose(handle);
    if (nativeBuffer != nullptr) {
      calloc.free(nativeBuffer);
    }
  }
}
