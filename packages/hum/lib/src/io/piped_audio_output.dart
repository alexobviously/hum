import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Configuration descriptor for an [AudioOutput] that streams interleaved raw
/// PCM bytes to a child subprocess (such as `ffplay` or `sox`) or an [IOSink].
///
/// When constructed via [PipedAudioOutput.ffplay] or [PipedAudioOutput.sox],
/// contains only immutable, isolate-sendable configuration. `IsolateAudioHost`
/// sends it across the isolate boundary and instantiates [PipedAudioOutputDriver]
/// directly on the background audio worker isolate.
class PipedAudioOutput({
  this._sink,
  this._process,
  final String? executable,
  final List<String> arguments = const [],
  @override required final int numChannels,
  @override required final int vectorSize,
  final WavFormat format = .float32,
}) extends AudioOutput {
  final IOSink? _sink;
  final Process? _process;

  /// Creates a [PipedAudioOutput] configured to stream audio into `ffplay`.
  ///
  /// The `ffplay` child process is spawned by [PipedAudioOutputDriver] inside
  /// the engine isolate when playback starts.
  new ffplay({
    required int numChannels,
    required int vectorSize,
    String executable = 'ffplay',
    int sampleRate = 44100,
    WavFormat format = .float32,
  }) : this(
         executable: executable,
         arguments: [
           '-f',
           switch (format) {
             .float32 => 'f32le',
             .pcm16 => 's16le',
           },
           '-ar',
           '$sampleRate',
           '-ch_layout',
           switch (numChannels) {
             1 => 'mono',
             2 => 'stereo',
             _ => '$numChannels',
           },
           '-nodisp',
           '-autoexit',
           '-probesize',
           '32',
           '-analyzeduration',
           '0',
           '-sync',
           'audio',
           '-',
         ],
         numChannels: numChannels,
         vectorSize: vectorSize,
         format: format,
       );

  /// Creates a [PipedAudioOutput] configured to stream audio into `sox` or `play`.
  ///
  /// The `sox`/`play` child process is spawned by [PipedAudioOutputDriver] inside
  /// the engine isolate when playback starts.
  new sox({
    required int numChannels,
    required int vectorSize,
    String executable = 'play',
    int sampleRate = 44100,
    WavFormat format = .float32,
  }) : this(
         executable: executable,
         arguments: [
           '-t',
           'raw',
           '-r',
           '$sampleRate',
           '-e',
           switch (format) {
             .float32 => 'float',
             .pcm16 => 'signed-integer',
           },
           '-b',
           switch (format) {
             .float32 => '32',
             .pcm16 => '16',
           },
           '-c',
           '$numChannels',
           '-q',
           '-',
         ],
         numChannels: numChannels,
         vectorSize: vectorSize,
         format: format,
       );

  @override
  bool get isIsolateSendable =>
      _sink == null && _process == null && executable != null;

  @override
  AudioOutputDriver createDriver() => PipedAudioOutputDriver(
    numChannels: numChannels,
    vectorSize: vectorSize,
    format: format,
    executable: executable,
    arguments: arguments,
    sink: _sink,
    process: _process,
  );
}

/// Runtime driver created by [PipedAudioOutput.createDriver].
///
/// Owns subprocess spawning, [BufferInterleaver], stdin flushing, and teardown
/// solely on the audio engine's execution thread/isolate.
class PipedAudioOutputDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
  final WavFormat format = .float32,
  final String? executable,
  final List<String> arguments = const [],
  this._sink,
  this._process,
}) extends AudioOutputDriver {
  IOSink? _sink;
  Process? _process;
  BufferInterleaver? _interleaver;
  final List<Uint8List> _pendingBuffer = [];
  bool _isSpawning = false;
  bool _isClosed = false;

  /// Whether this driver has been closed (including permanently disabled on spawn error).
  bool get isClosed => _isClosed;

  /// The active child subprocess, if spawned.
  Process? get process => _process;

  void _ensureStarted() {
    if (_sink != null || _isSpawning || _isClosed || executable == null) return;
    _isSpawning = true;
    Process.start(executable!, arguments)
        .then((p) {
          _isSpawning = false;
          if (_isClosed) {
            _pendingBuffer.clear();
            p.kill();
            return;
          }
          _process = p;
          _sink = p.stdin;
          for (final pending in _pendingBuffer) {
            _sink!.add(pending);
          }
          _pendingBuffer.clear();
        })
        .catchError((_) {
          _isSpawning = false;
          _isClosed = true;
          _pendingBuffer.clear();
        });
  }

  @override
  void start(ProcessContext context) {
    _ensureStarted();
  }

  @override
  void write(List<Float32List> channels) {
    if (_isClosed) return;
    final interleaver = _interleaver ??= BufferInterleaver(
      numChannels: numChannels,
      vectorSize: vectorSize,
    );
    final byteView = switch (format) {
      .float32 => interleaver.interleaveFloat32Bytes(channels),
      .pcm16 => interleaver.interleavePcm16Bytes(channels),
    };
    // Copy bytes so asynchronous IOSink queue does not read mutated buffer memory.
    final copiedBytes = Uint8List.fromList(byteView);
    if (_sink != null) {
      _sink!.add(copiedBytes);
    } else if (executable != null) {
      _pendingBuffer.add(copiedBytes);
      _ensureStarted();
    }
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    if (_isClosed) return;
    _isClosed = true;
    while (_isSpawning) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    if (waitForExit && _process != null) {
      await _process!.exitCode;
    } else {
      _process?.kill();
    }
    _process = null;
    _sink = null;
    _pendingBuffer.clear();
  }
}
