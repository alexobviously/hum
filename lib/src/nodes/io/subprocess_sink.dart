import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// A terminal audio node that streams interleaved PCM audio blocks directly into
/// a child subprocess's standard input (such as `ffplay` or `sox`).
///
/// Holds only sendable primitives ([executable], [arguments], [format]), making it
/// 100% safe to serialize across Dart isolate boundaries. The underlying [Process]
/// is spawned lazily on the audio worker isolate by [SubprocessSinkProcessor].
class SubprocessSink({
  required final List<Outlet> channels,
  required final String executable,
  final List<String> arguments = const [],
  final WavFormat format = .float32,
}) extends TerminalNode<SubprocessSinkProcessor> {
  /// Creates a sink configured to pipe audio into `ffplay`.
  SubprocessSink.ffplay({
    required List<Outlet> channels,
    String executable = 'ffplay',
    int sampleRate = 44100,
    WavFormat format = .float32,
  }) : this(
         channels: channels,
         executable: executable,
         arguments: [
           //
           '-f', format == .float32 ? 'f32le' : 's16le',
           '-ar', '$sampleRate',
           '-ch_layout', channels.length == 1 ? 'mono' : 'stereo',
           '-nodisp',
           '-autoexit',
           '-probesize', '32',
           '-analyzeduration', '0',
           '-sync', 'audio',
           '-', // this means read from stdin instead of a file
         ],
         format: format,
       );

  /// Creates a sink configured to pipe audio into `sox` or `play`.
  SubprocessSink.sox({
    required List<Outlet> channels,
    String executable = 'play',
    int sampleRate = 44100,
    WavFormat format = .float32,
  }) : this(
         channels: channels,
         executable: executable,
         arguments: [
           //
           '-t', 'raw',
           '-r', '$sampleRate',
           '-e', format == .float32 ? 'float' : 'signed-integer',
           '-b', format == .float32 ? '32' : '16',
           '-c', '${channels.length}',
           '-q',
           '-',
         ],
         format: format,
       );

  @override
  List<Inlet> get inlets => List.generate(
    channels.length,
    (i) => Inlet(node: this, index: i, source: channels[i]),
  );

  @override
  SubprocessSinkProcessor createProcessor() => SubprocessSinkProcessor(
    executable: executable,
    arguments: arguments,
    numChannels: channels.length,
    format: format,
  );

  @override
  Object get params => ();

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeParamError(param: 'channels', error: 'must not be empty'),
    if (executable.trim().isEmpty)
      const AudioNodeParamError(
        param: 'executable',
        error: 'must not be empty',
      ),
  ];

  @override
  bool canUpdate(covariant SubprocessSink newNode) =>
      super.canUpdate(newNode) &&
      executable == newNode.executable &&
      format == newNode.format &&
      channels.length == newNode.channels.length &&
      _listsEqual(arguments, newNode.arguments);

  static bool _listsEqual(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The runtime processor for [SubprocessSink].
class SubprocessSinkProcessor({
  required final String executable,
  required final List<String> arguments,
  required final int numChannels,
  final WavFormat format = .float32,
}) implements DisposableAudioProcessor {
  Process? _process;
  IOSink? _stdin;
  BufferInterleaver? _interleaver;
  final List<Uint8List> _pendingBuffer = [];
  bool _isSpawning = false;
  bool _isClosed = false;

  /// Whether this sink has been closed.
  bool get isClosed => _isClosed;

  /// The active subprocess, or null if not yet spawned or closed.
  Process? get subprocess => _process;

  void _ensureStarted() {
    if (_process != null || _isSpawning || _isClosed) return;
    _isSpawning = true;
    Process.start(executable, arguments)
        .then((p) {
          if (_isClosed) {
            p.kill();
            return;
          }
          _process = p;
          _stdin = p.stdin;
          _isSpawning = false;
          for (final pending in _pendingBuffer) {
            _stdin!.add(pending);
          }
          _pendingBuffer.clear();
        })
        .catchError((_) {
          _isSpawning = false;
          _pendingBuffer.clear();
        });
  }

  /// Ensures the child process has spawned and is ready to receive audio blocks.
  Future<void> ensureStarted() async {
    if (_stdin != null) return;
    _ensureStarted();
    while (_stdin == null && !_isClosed && _isSpawning) {
      await Future.delayed(const Duration(milliseconds: 2));
    }
  }

  @override
  void update(Object params) {}

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    if (_isClosed) return;

    BufferInterleaver? interleaver = _interleaver;
    if (interleaver == null || interleaver.vectorSize != context.vectorSize) {
      interleaver = _interleaver = BufferInterleaver(
        numChannels: numChannels,
        vectorSize: context.vectorSize,
      );
    }

    final byteView = switch (format) {
      .float32 => interleaver.interleaveFloat32Bytes(inputs),
      .pcm16 => interleaver.interleavePcm16Bytes(inputs),
    };

    // Dart IOSink.add queues references to the list rather than copying.
    // We must pass a copy so subsequent audio blocks do not mutate queued bytes
    // before the OS pipe writes them.
    final copiedBytes = Uint8List.fromList(byteView);

    if (_stdin != null) {
      _stdin!.add(copiedBytes);
    } else {
      _pendingBuffer.add(copiedBytes);
      _ensureStarted();
    }
  }

  /// Flushes standard input and waits for the subprocess to finish playing before exiting.
  Future<void> close({bool waitForExit = true}) async {
    if (_isClosed) return;
    _isClosed = true;
    while (_isSpawning) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
    if (_stdin != null) {
      try {
        await _stdin!.flush();
        await _stdin!.close();
      } catch (_) {}
    }
    if (waitForExit && _process != null) {
      await _process!.exitCode;
    } else {
      _process?.kill();
    }
    _process = null;
    _stdin = null;
    _pendingBuffer.clear();
  }

  @override
  Future<void> dispose() async {
    await close(waitForExit: false);
  }
}
