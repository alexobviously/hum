import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';

// TODO: refactor(PipedAudioOutput): Split into a pure configuration descriptor
// (e.g. SubprocessAudioOutputConfig) and an audio-thread runtime driver created
// inside the host/worker isolate. Currently, sending a PipedAudioOutput across
// IsolateAudioHost.startPlayback clones this object onto the worker isolate: the
// worker copy spawns and owns `_process` and `_sink`, while the main isolate's
// reference remains an unstarted shell whose `close()` is a no-op.

/// An [AudioOutput] that interleaves multi-channel audio and writes raw bytes to
/// a child subprocess's standard input (such as `ffplay` or `sox`) or an [IOSink].
///
/// When created via [PipedAudioOutput.ffplay] or [PipedAudioOutput.sox], holds only
/// sendable primitives ([executable], [arguments], [format]) until playback starts,
/// allowing [IsolateAudioHost] to send it into the background audio worker isolate
/// and spawn the child process directly on the audio thread.
class PipedAudioOutput implements AudioOutput {
  @override
  final int numChannels;

  @override
  final int vectorSize;

  final WavFormat format;
  final String? executable;
  final List<String> arguments;

  IOSink? _sink;
  Process? _process;
  BufferInterleaver? _interleaver;
  final List<Uint8List> _pendingBuffer = [];
  bool _isSpawning = false;
  bool _isClosed = false;

  /// Creates a [PipedAudioOutput] writing to an existing [sink] or spawning [executable].
  PipedAudioOutput({
    this._sink,
    this._process,
    this.executable,
    this.arguments = const [],
    required this.numChannels,
    required this.vectorSize,
    this.format = .float32,
  });

  /// Creates a [PipedAudioOutput] configured to stream audio into `ffplay`.
  ///
  /// The `ffplay` process is spawned lazily when playback begins (inside the audio
  /// worker isolate when used with [IsolateAudioHost]).
  PipedAudioOutput.ffplay({
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
  /// The `sox`/`play` process is spawned lazily when playback begins (inside the audio
  /// worker isolate when used with [IsolateAudioHost]).
  PipedAudioOutput.sox({
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

  /// Whether this output can be sent across a Dart isolate boundary to run on the worker isolate.
  bool get isIsolateSendable =>
      _sink == null && _process == null && executable != null;

  /// Whether this output has been closed.
  bool get isClosed => _isClosed;

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
