import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:hum/hum.dart';

import 'cpal_bindings.dart';
import 'cpal_playback_pacer.dart';

/// Immutable, isolate-sendable configuration descriptor for an [AudioInput]
/// that captures live audio from a native `cpal` hardware input device.
///
/// Selecting `deviceId == null` opens the host's default input device.
///
/// [bufferFrames] controls the Rust lock-free `rtrb` ring buffer capacity
/// between the OS audio thread and Dart (defaults to `2048` frames).
///
/// [hardwareBufferFrames] optionally requests a fixed OS/hardware callback
/// period (`cpal::BufferSize::Fixed(n)`), e.g. `64` or `128` for low-latency
/// live monitoring or guitar pedalboards. Leave `null` (default) to let the OS
/// choose its default period size (`cpal::BufferSize::Default`). When set, it
/// must fall within the device's supported [CpalBufferSizeRange].
class const CpalAudioInput({
  @override required final int numChannels,
  @override required final int vectorSize,
  final String? deviceId,
  final int bufferFrames = 2048,
  final int? hardwareBufferFrames,
}) extends AudioInput {
  this
    : assert(numChannels > 0, 'numChannels must be positive'),
      assert(vectorSize > 0, 'vectorSize must be positive'),
      assert(
        bufferFrames >= vectorSize,
        'bufferFrames must be at least vectorSize',
      ),
      assert(
        hardwareBufferFrames == null || hardwareBufferFrames > 0,
        'hardwareBufferFrames must be positive when provided',
      );

  @override
  bool get isIsolateSendable => true;

  @override
  AudioInputDriver createDriver() => CpalAudioInputDriver(
    numChannels: numChannels,
    vectorSize: vectorSize,
    deviceId: deviceId,
    bufferFrames: bufferFrames,
    hardwareBufferFrames: hardwareBufferFrames,
  );
}

/// Runtime capture driver created by [CpalAudioInput.createDriver].
///
/// Owns the native [HumCaptureHandle], a persistent interleaved [Float32List]
/// staging buffer over native memory, and input pacing via [CpalPlaybackPacer].
class CpalAudioInputDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
  final String? deviceId,
  final int bufferFrames = 2048,
  final int? hardwareBufferFrames,
}) extends AudioInputDriver {
  Pointer<HumCaptureHandle> _handle = nullptr;
  Pointer<Float> _nativeBuffer = nullptr;
  Float32List? _nativeView;
  int _underruns = 0;
  bool _isClosed = false;

  /// Whether the native `cpal` capture stream handle is currently open.
  bool get isOpen => _handle != nullptr;

  /// Whether [close] has been called on this driver.
  bool get isClosed => _isClosed;

  /// Whether the stream has stopped due to a hardware error or is closed.
  bool get isStopped => _handle == nullptr || humCpalCaptureIsStopped(_handle);

  /// Interleaved frames currently buffered and ready to read from the ring
  /// buffer.
  int get availableReadFrames =>
      _handle == nullptr ? 0 : humCpalCaptureAvailableRead(_handle);

  /// Hardware callback overrun count observed since [start].
  int get overruns => _handle == nullptr ? 0 : humCpalCaptureOverruns(_handle);

  /// Read underrun count (blocks where fewer than [vectorSize] frames were
  /// ready and the remainder was zero-filled).
  int get underruns => _underruns;

  @override
  void start(ProcessContext context) {
    if (_isClosed) {
      throw StateError('CpalAudioInputDriver has been closed.');
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
    if (hardwareBufferFrames != null && hardwareBufferFrames! <= 0) {
      throw ArgumentError.value(
        hardwareBufferFrames,
        'hardwareBufferFrames',
        'Must be positive when provided',
      );
    }

    final outError = calloc<Pointer<Utf8>>();
    final deviceIdPtr = deviceId?.toNativeUtf8() ?? nullptr;

    Pointer<HumCaptureHandle> handle = nullptr;
    try {
      handle = humCpalCaptureCreate(
        deviceIdPtr,
        context.sampleRate,
        numChannels,
        bufferFrames,
        hardwareBufferFrames ?? 0,
        outError,
      );

      if (handle == nullptr) {
        final errPtr = outError.value;

        final String message;
        if (errPtr != nullptr) {
          message = errPtr.toDartString();
          humCpalFreeString(errPtr);
        } else {
          message = 'Failed to create cpal capture stream.';
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
        humCpalCaptureClose(handle);
      }
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
        'Cannot create a pacer before CpalAudioInputDriver.start().',
      );
    }

    return CpalPlaybackPacer(
      sampleRate: context.sampleRate,
      vectorSize: vectorSize,
      availableFrames: () => availableReadFrames,
      isStopped: () => _isClosed || isStopped,
    );
  }

  @override
  void read(List<Float32List> channels) {
    final handle = _handle;
    final nativeView = _nativeView;
    if (_isClosed || handle == nullptr || nativeView == null) {
      for (final ch in channels) {
        ch.fillRange(0, vectorSize, 0.0);
      }
      return;
    }

    if (humCpalCaptureIsStopped(handle)) {
      _throwStreamError(handle);
    }

    final readFrames = humCpalCaptureRead(handle, _nativeBuffer, vectorSize);
    if (readFrames < vectorSize) {
      if (humCpalCaptureIsStopped(handle)) {
        _throwStreamError(handle);
      }
      _underruns++;
      nativeView.fillRange(
        readFrames * numChannels,
        vectorSize * numChannels,
        0.0,
      );
    }

    deinterleaveFloats(nativeView, channels, vectorSize: vectorSize);
  }

  Never _throwStreamError(Pointer<HumCaptureHandle> handle) {
    final errPtr = humCpalCaptureTakeError(handle);

    final String message;
    if (errPtr != nullptr) {
      message = errPtr.toDartString();
      humCpalFreeString(errPtr);
    } else {
      message = 'cpal capture stream stopped unexpectedly.';
    }

    throw StateError(message);
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    if (_isClosed) return;
    _isClosed = true;

    final handle = _handle;
    final nativeBuffer = _nativeBuffer;
    _handle = nullptr;
    _nativeBuffer = nullptr;
    _nativeView = null;

    humCpalCaptureClose(handle);
    if (nativeBuffer != nullptr) {
      calloc.free(nativeBuffer);
    }
  }
}
