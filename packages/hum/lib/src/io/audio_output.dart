import 'dart:async';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Immutable configuration descriptor for an audio playback destination.
///
/// Mirrors [AudioNode] on the control/UI side: holds configuration and
/// instantiates a mutable runtime [AudioOutputDriver] via [createDriver] on the
/// isolate or thread running [AudioEngine].
abstract class const AudioOutput() {
  /// The number of audio channels expected by this destination.
  int get numChannels;

  /// The vector size (samples per channel) of each audio block.
  int get vectorSize;

  /// Whether this descriptor can be sent across a Dart isolate boundary so
  /// `IsolateAudioHost` can create and run its [AudioOutputDriver] directly on
  /// the background audio worker isolate.
  ///
  /// Implementations containing only sendable configuration (such as
  /// subprocess configs, native FFI descriptors, or [NullAudioOutput]) return
  /// `true`. Host-bound outputs (such as [MemoryAudioOutput]) return `false`.
  bool get isIsolateSendable => false;

  /// Instantiates the mutable runtime driver for this output configuration.
  AudioOutputDriver createDriver();

  /// Combines multiple [AudioOutput] descriptors into a single broadcasting output.
  static AudioOutput combine(List<AudioOutput> outputs) =>
      CombinedAudioOutput(outputs: outputs);

  /// A no-op audio output that silently drops all written blocks.
  static AudioOutput none({int numChannels = 2, int vectorSize = 64}) =>
      NullAudioOutput(numChannels: numChannels, vectorSize: vectorSize);
}

/// Mutable runtime sink created by [AudioOutput.createDriver].
///
/// Analogous to [AudioProcessor]: owned and driven exclusively by a single
/// execution context (either the background worker isolate or caller thread).
abstract class const AudioOutputDriver() {
  /// The number of audio channels expected in [write].
  int get numChannels;

  /// The vector size (samples per channel) expected in [write].
  int get vectorSize;

  /// Initializes any external OS, hardware, or subprocess resources.
  FutureOr<void> start(ProcessContext context) {}

  /// Optionally provides a custom [PlaybackPacer] (e.g. hardware DAC
  /// ring-buffer backpressure). Returning `null` selects the host's default
  /// [StopwatchPlaybackPacer].
  PlaybackPacer? createPacer(ProcessContext context) => null;

  /// Writes one block of multi-channel audio to the destination.
  ///
  /// Zero heap allocations should occur during steady-state calls.
  void write(List<Float32List> channels);

  /// Flushes pending audio and releases resources held by this driver.
  ///
  /// When [waitForExit] is `false`, implementations backed by external processes
  /// or hardware threads terminate immediately rather than draining.
  Future<void> close({bool waitForExit = true});
}

/// A host-bound [AudioOutput] that accumulates interleaved audio bytes in RAM.
///
/// Ideal for unit tests and in-memory capture across both [SyncAudioHost] and
/// `IsolateAudioHost`. Because [bytes] must remain readable on the caller
/// isolate, [isIsolateSendable] is `false`.
class MemoryAudioOutput({
  @override required final int numChannels,
  @override required final int vectorSize,
  final WavFormat format = .float32,
}) extends AudioOutput {
  final BufferInterleaver _interleaver = BufferInterleaver(
    numChannels: numChannels,
    vectorSize: vectorSize,
  );
  final BytesBuilder _builder = BytesBuilder(copy: true);
  bool _isClosed = false;

  /// The accumulated bytes written to this output.
  Uint8List get bytes => _builder.toBytes();

  /// The total number of bytes written so far.
  int get length => _builder.length;

  /// Whether the active driver for this output has been closed.
  bool get isClosed => _isClosed;

  /// Instantiates a driver that appends interleaved bytes to this buffer.
  ///
  /// Reusing the same [MemoryAudioOutput] across multiple playback sessions
  /// resets [isClosed] and appends to existing [bytes].
  @override
  AudioOutputDriver createDriver() {
    _isClosed = false;
    return MemoryAudioOutputDriver(this);
  }
}

/// Runtime driver for [MemoryAudioOutput].
class MemoryAudioOutputDriver(final MemoryAudioOutput _output)
    extends AudioOutputDriver {
  @override
  int get numChannels => _output.numChannels;

  @override
  int get vectorSize => _output.vectorSize;

  @override
  void write(List<Float32List> channels) {
    if (_output._isClosed) return;
    final byteView = switch (_output.format) {
      .float32 => _output._interleaver.interleaveFloat32Bytes(channels),
      .pcm16 => _output._interleaver.interleavePcm16Bytes(channels),
    };
    _output._builder.add(byteView);
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    _output._isClosed = true;
  }
}

/// An [AudioOutput] that broadcasts written audio blocks to multiple outputs.
class CombinedAudioOutput({
  required final List<AudioOutput> outputs,
}) extends AudioOutput {
  this {
    if (outputs.length > 1) {
      final expectedChannels = outputs.first.numChannels;
      final expectedVectorSize = outputs.first.vectorSize;

      for (int i = 1; i < outputs.length; i++) {
        final output = outputs[i];
        if (output.numChannels != expectedChannels ||
            output.vectorSize != expectedVectorSize) {
          throw ArgumentError(
            'Combined outputs must match numChannels ($expectedChannels) and '
            'vectorSize ($expectedVectorSize), but output[$i] has '
            'numChannels=${output.numChannels}, vectorSize=${output.vectorSize}.',
          );
        }
      }
    }
  }

  @override
  int get numChannels => outputs.isNotEmpty ? outputs.first.numChannels : 0;

  @override
  int get vectorSize => outputs.isNotEmpty ? outputs.first.vectorSize : 0;

  @override
  bool get isIsolateSendable => outputs.every((o) => o.isIsolateSendable);

  @override
  AudioOutputDriver createDriver() => CombinedAudioOutputDriver(
    drivers: [for (final output in outputs) output.createDriver()],
  );
}

/// Runtime driver that broadcasts blocks to multiple [AudioOutputDriver]s.
class CombinedAudioOutputDriver({
  required final List<AudioOutputDriver> drivers,
}) extends AudioOutputDriver {
  @override
  int get numChannels => drivers.isNotEmpty ? drivers.first.numChannels : 0;

  @override
  int get vectorSize => drivers.isNotEmpty ? drivers.first.vectorSize : 0;

  @override
  Future<void> start(ProcessContext context) async {
    int startedCount = 0;
    try {
      for (int i = 0; i < drivers.length; i++) {
        final result = drivers[i].start(context);
        if (result is Future<void>) {
          await result;
        }
        startedCount = i + 1;
      }
    } catch (_) {
      for (int i = startedCount - 1; i >= 0; i--) {
        try {
          await drivers[i].close(waitForExit: false);
        } catch (_) {}
      }
      rethrow;
    }
  }

  @override
  PlaybackPacer? createPacer(ProcessContext context) {
    for (int i = 0; i < drivers.length; i++) {
      final pacer = drivers[i].createPacer(context);
      if (pacer != null) return pacer;
    }
    return null;
  }

  @override
  void write(List<Float32List> channels) {
    for (int i = 0; i < drivers.length; i++) {
      drivers[i].write(channels);
    }
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    for (int i = 0; i < drivers.length; i++) {
      await drivers[i].close(waitForExit: waitForExit);
    }
  }
}

/// A no-op [AudioOutput] descriptor that drops all blocks without processing.
class const NullAudioOutput({
  @override required final int numChannels,
  @override required final int vectorSize,
}) extends AudioOutput {
  @override
  bool get isIsolateSendable => true;

  @override
  AudioOutputDriver createDriver() =>
      NullAudioOutputDriver(numChannels: numChannels, vectorSize: vectorSize);
}

/// Runtime driver for [NullAudioOutput].
class NullAudioOutputDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
}) extends AudioOutputDriver {
  @override
  void write(List<Float32List> channels) {}

  @override
  Future<void> close({bool waitForExit = true}) async {}
}
