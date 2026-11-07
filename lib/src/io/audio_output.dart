import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// An abstraction for audio output destinations (subprocesses, native DAC, memory).
abstract interface class AudioOutput {
  /// The number of audio channels.
  int get numChannels;

  /// The vector size of each audio block.
  int get vectorSize;

  /// Writes one block of multi-channel audio to the destination.
  ///
  /// Zero heap allocations should occur during this call.
  void write(List<Float32List> channels);

  /// Closes the output destination and releases any associated resources.
  Future<void> close();

  /// Combines multiple [AudioOutput] destinations into a single broadcasting output.
  static AudioOutput combine(List<AudioOutput> outputs) =>
      CombinedAudioOutput(outputs: outputs);

  /// A no-op audio output that silently drops all written blocks.
  static AudioOutput none({int numChannels = 2, int vectorSize = 64}) =>
      NullAudioOutput(numChannels: numChannels, vectorSize: vectorSize);
}

/// An [AudioOutput] that interleaves multi-channel audio and writes raw bytes to an [IOSink].
///
/// Ideal for streaming PCM audio into subprocesses such as `ffplay` or `sox`.
class PipedAudioOutput({
  required final IOSink sink,
  @override required final int numChannels,
  @override required final int vectorSize,
  final WavFormat format = .float32,
  final Process? process,
}) implements AudioOutput {
  final BufferInterleaver _interleaver = BufferInterleaver(
    numChannels: numChannels,
    vectorSize: vectorSize,
  );
  bool _isClosed = false;

  /// Whether this output has been closed.
  bool get isClosed => _isClosed;

  /// Spawns `ffplay` with optimal low-latency flags and returns a [PipedAudioOutput].
  static Future<PipedAudioOutput> ffplay({
    required int numChannels,
    required int vectorSize,
    String executable = 'ffplay',
    int sampleRate = 44100,
    WavFormat format = .float32,
  }) async {
    final formatFlag = switch (format) {
      .float32 => 'f32le',
      .pcm16 => 's16le',
    };
    final layout = switch (numChannels) {
      1 => 'mono',
      2 => 'stereo',
      _ => '$numChannels',
    };

    final process = await Process.start(
      executable,
      [
        //
        '-f', formatFlag,
        '-ar', '$sampleRate',
        '-ch_layout', layout,
        '-nodisp',
        '-autoexit',
        '-probesize', '32',
        '-analyzeduration', '0',
        '-sync', 'audio',
        '-',
      ],
      mode: ProcessStartMode.normal,
    );

    return PipedAudioOutput(
      sink: process.stdin,
      numChannels: numChannels,
      vectorSize: vectorSize,
      format: format,
      process: process,
    );
  }

  /// Spawns `sox` or `play` with raw PCM flags and returns a [PipedAudioOutput].
  static Future<PipedAudioOutput> sox({
    required int numChannels,
    required int vectorSize,
    String executable = 'play',
    int sampleRate = 44100,
    WavFormat format = .float32,
  }) async {
    final encoding = switch (format) {
      .float32 => 'float',
      .pcm16 => 'signed-integer',
    };
    final bitDepth = switch (format) {
      .float32 => '32',
      .pcm16 => '16',
    };

    final process = await Process.start(
      executable,
      [
        //
        '-t', 'raw',
        '-r', '$sampleRate',
        '-e', encoding,
        '-b', bitDepth,
        '-c', '$numChannels',
        '-q',
        '-',
      ],
      mode: ProcessStartMode.normal,
    );

    return PipedAudioOutput(
      sink: process.stdin,
      numChannels: numChannels,
      vectorSize: vectorSize,
      format: format,
      process: process,
    );
  }

  @override
  void write(List<Float32List> channels) {
    if (_isClosed) return;
    final byteView = switch (format) {
      .float32 => _interleaver.interleaveFloat32Bytes(channels),
      .pcm16 => _interleaver.interleavePcm16Bytes(channels),
    };
    // Copy bytes so asynchronous IOSink queue does not read mutated buffer memory.
    sink.add(Uint8List.fromList(byteView));
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    if (_isClosed) return;
    _isClosed = true;
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {}
    if (waitForExit && process != null) {
      await process!.exitCode;
    } else {
      process?.kill();
    }
  }
}

/// An in-memory [AudioOutput] that accumulates interleaved byte blocks.
///
/// Ideal for testing, unit tests, and memory buffering without subprocesses.
class MemoryAudioOutput({
  @override required final int numChannels,
  @override required final int vectorSize,
  final WavFormat format = .float32,
}) implements AudioOutput {
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

  /// Whether this output has been closed.
  bool get isClosed => _isClosed;

  @override
  void write(List<Float32List> channels) {
    if (_isClosed) return;
    final byteView = switch (format) {
      .float32 => _interleaver.interleaveFloat32Bytes(channels),
      .pcm16 => _interleaver.interleavePcm16Bytes(channels),
    };
    _builder.add(byteView);
  }

  @override
  Future<void> close() async {
    _isClosed = true;
  }
}

/// An [AudioOutput] that broadcasts written audio blocks to multiple destinations.
class CombinedAudioOutput({
  required final List<AudioOutput> outputs,
}) implements AudioOutput {
  @override
  int get numChannels => outputs.isNotEmpty ? outputs.first.numChannels : 0;

  @override
  int get vectorSize => outputs.isNotEmpty ? outputs.first.vectorSize : 0;

  @override
  void write(List<Float32List> channels) {
    for (int i = 0; i < outputs.length; i++) {
      outputs[i].write(channels);
    }
  }

  @override
  Future<void> close() async {
    for (int i = 0; i < outputs.length; i++) {
      await outputs[i].close();
    }
  }
}

/// A no-op [AudioOutput] that safely drops all blocks without processing.
class NullAudioOutput({
  @override required final int numChannels,
  @override required final int vectorSize,
}) implements AudioOutput {
  @override
  void write(List<Float32List> channels) {}

  @override
  Future<void> close() async {}
}
