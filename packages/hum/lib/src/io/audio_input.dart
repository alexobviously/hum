import 'dart:async';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Immutable configuration descriptor for an audio capture/input source.
///
/// Mirrors [AudioOutput] on the input side: holds configuration and
/// instantiates a mutable runtime [AudioInputDriver] via [createDriver] on the
/// isolate or thread running [AudioEngine].
abstract class const AudioInput() {
  /// The number of audio channels provided by this input source.
  int get numChannels;

  /// The vector size (samples per channel) filled per [AudioInputDriver.read].
  int get vectorSize;

  /// Whether this descriptor can be sent across a Dart isolate boundary so
  /// `IsolateAudioHost` can create and run its [AudioInputDriver] directly on
  /// the background audio worker isolate.
  bool get isIsolateSendable => false;

  /// Instantiates the mutable runtime driver for this input configuration.
  AudioInputDriver createDriver();

  /// A silent [AudioInput] that fills all channels with zeros.
  static AudioInput none({int numChannels = 1, int vectorSize = 64}) =>
      NullAudioInput(numChannels: numChannels, vectorSize: vectorSize);
}

/// Mutable runtime capture driver created by [AudioInput.createDriver].
///
/// Mirrors [AudioOutputDriver]: owned and driven exclusively by a single
/// execution context (either the background worker isolate or caller thread).
abstract class const AudioInputDriver() {
  /// The number of audio channels expected in [read].
  int get numChannels;

  /// The vector size (samples per channel) expected in [read].
  int get vectorSize;

  /// Initializes any external OS, hardware, or stream resources.
  FutureOr<void> start(ProcessContext context) {}

  /// Optionally provides a custom [PlaybackPacer] (e.g. hardware capture
  /// ring-buffer readiness) used when no [AudioOutputDriver] pacer is active.
  /// Returning `null` selects the host's default [StopwatchPlaybackPacer].
  PlaybackPacer? createPacer(ProcessContext context) => null;

  /// Fills one block of multi-channel audio into [channels] in-place.
  ///
  /// Zero heap allocations should occur during steady-state calls. On underrun,
  /// implementations should zero-fill missing samples rather than blocking.
  void read(List<Float32List> channels);

  /// Stops capture and releases resources held by this driver.
  Future<void> close({bool waitForExit = true});
}

/// An isolate-sendable [AudioInput] that feeds pre-recorded channel buffers
/// from memory into the audio engine.
///
/// Ideal for unit tests and offline processing without hardware devices.
class const MemoryAudioInput({
  required final List<Float32List> channels,
  @override required final int vectorSize,
  final bool loop = false,
}) extends AudioInput {
  @override
  int get numChannels => channels.length;

  @override
  bool get isIsolateSendable => true;

  @override
  AudioInputDriver createDriver() => MemoryAudioInputDriver(
    channels: channels,
    vectorSize: vectorSize,
    loop: loop,
  );
}

/// Runtime driver for [MemoryAudioInput].
class MemoryAudioInputDriver({
  required final List<Float32List> channels,
  @override required final int vectorSize,
  final bool loop = false,
}) extends AudioInputDriver {
  int _readOffset = 0;
  bool _isClosed = false;

  @override
  int get numChannels => channels.length;

  /// Whether this driver has been closed.
  bool get isClosed => _isClosed;

  /// Current sample read offset across the source buffers.
  int get readOffset => _readOffset;

  @override
  void read(List<Float32List> target) {
    // brrrrr
    final chCount = target.length < channels.length
        ? target.length
        : channels.length;

    if (_isClosed || chCount == 0) {
      for (int c = 0; c < target.length; c++) {
        target[c].fillRange(0, vectorSize, 0.0);
      }
      return;
    }

    final totalLength = channels[0].length;
    if (totalLength == 0) {
      for (int c = 0; c < target.length; c++) {
        target[c].fillRange(0, vectorSize, 0.0);
      }
      return;
    }

    if (loop) {
      int pos = _readOffset;
      for (int i = 0; i < vectorSize; i++) {
        for (int c = 0; c < chCount; c++) {
          target[c][i] = channels[c][pos];
        }
        pos++;
        if (pos >= totalLength) pos = 0;
      }
      _readOffset = pos;
    } else {
      final remaining = totalLength - _readOffset;
      final toCopy = remaining <= 0
          ? 0
          : (remaining < vectorSize ? remaining : vectorSize);

      for (int c = 0; c < chCount; c++) {
        if (toCopy > 0) {
          target[c].setRange(0, toCopy, channels[c], _readOffset);
        }
        if (toCopy < vectorSize) {
          target[c].fillRange(toCopy, vectorSize, 0.0);
        }
      }
      _readOffset += toCopy;
    }

    for (int c = chCount; c < target.length; c++) {
      target[c].fillRange(0, vectorSize, 0.0);
    }
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    _isClosed = true;
  }
}

/// A no-op [AudioInput] descriptor that produces silence on all channels.
class const NullAudioInput({
  @override required final int numChannels,
  @override required final int vectorSize,
}) extends AudioInput {
  @override
  bool get isIsolateSendable => true;

  @override
  AudioInputDriver createDriver() =>
      NullAudioInputDriver(numChannels: numChannels, vectorSize: vectorSize);
}

/// Runtime driver for [NullAudioInput].
class NullAudioInputDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
}) extends AudioInputDriver {
  @override
  void read(List<Float32List> channels) {
    for (int c = 0; c < channels.length; c++) {
      channels[c].fillRange(0, vectorSize, 0.0);
    }
  }

  @override
  Future<void> close({bool waitForExit = true}) async {}
}
