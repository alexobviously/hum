import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// An audio input source node that streams PCM audio from a child subprocess's
/// standard output (such as `sox`, `rec`, or `ffmpeg`).
///
/// Holds only sendable primitives ([executable], [arguments], [numChannels], [format]),
/// making it 100% safe to serialize across Dart isolate boundaries. The underlying
/// [Process] is spawned lazily on the audio worker isolate by [SubprocessSourceProcessor].
class SubprocessSource({
  required final String executable,
  final List<String> arguments = const [],
  final int numChannels = 1,
  final WavFormat format = .float32,
  final int sampleRate = 44100,
  final int bufferCapacity = 1048576,
}) extends AudioNode<SubprocessSourceProcessor> {
  /// Creates a source configured to pipe audio from `sox` or `rec`.
  ///
  /// By default, captures audio from the system's default input ([input] = `'-d'`).
  /// Pass an audio file path to decode from disk instead.
  SubprocessSource.sox({
    int numChannels = 1,
    String executable = 'sox',
    String input = '-d',
    int sampleRate = 44100,
    WavFormat format = .float32,
    int bufferCapacity = 1048576,
  }) : this(
         executable: executable,
         arguments: [
           '-q',
           input,
           '-t',
           'raw',
           '-r',
           '$sampleRate',
           '-c',
           '$numChannels',
           '-b',
           format == .float32 ? '32' : '16',
           '-e',
           format == .float32 ? 'floating-point' : 'signed-integer',
           '-',
         ],
         numChannels: numChannels,
         format: format,
         sampleRate: sampleRate,
         bufferCapacity: bufferCapacity,
       );

  /// Creates a source configured to pipe audio from `rec` (SoX recording utility).
  SubprocessSource.rec({
    int numChannels = 1,
    String executable = 'rec',
    int sampleRate = 44100,
    WavFormat format = .float32,
    int bufferCapacity = 1048576,
  }) : this(
         executable: executable,
         arguments: [
           '-q',
           '-t',
           'raw',
           '-r',
           '$sampleRate',
           '-c',
           '$numChannels',
           '-b',
           format == .float32 ? '32' : '16',
           '-e',
           format == .float32 ? 'floating-point' : 'signed-integer',
           '-',
         ],
         numChannels: numChannels,
         format: format,
         sampleRate: sampleRate,
         bufferCapacity: bufferCapacity,
       );

  /// Creates a source configured to pipe audio from `ffmpeg`.
  ///
  /// The input counterpart to [SubprocessSink.ffplay].
  ///
  /// If [input] is `':default'` or starts with `':'`, it captures from the system's
  /// audio device (via AVFoundation on macOS).
  /// Pass an audio file path to decode from disk instead.
  SubprocessSource.ffmpeg({
    int numChannels = 1,
    String executable = 'ffmpeg',
    String input = ':default',
    int sampleRate = 44100,
    WavFormat format = .float32,
    int bufferCapacity = 1048576,
  }) : this(
         executable: executable,
         arguments: [
           '-loglevel',
           'quiet',
           if (input.startsWith(':')) ...['-f', 'avfoundation'],
           '-i',
           input,
           '-f',
           format == .float32 ? 'f32le' : 's16le',
           '-ac',
           '$numChannels',
           '-ar',
           '$sampleRate',
           '-',
         ],
         numChannels: numChannels,
         format: format,
         sampleRate: sampleRate,
         bufferCapacity: bufferCapacity,
       );

  /// Automatically selects the best available microphone capture tool (`sox`, `rec`, or `ffmpeg`).
  factory SubprocessSource.mic({
    int numChannels = 1,
    int sampleRate = 44100,
    WavFormat format = .float32,
    int bufferCapacity = 1048576,
  }) {
    if (_isCommandAvailable('sox')) {
      return SubprocessSource.sox(
        numChannels: numChannels,
        sampleRate: sampleRate,
        format: format,
        bufferCapacity: bufferCapacity,
      );
    }
    if (_isCommandAvailable('rec')) {
      return SubprocessSource.rec(
        numChannels: numChannels,
        sampleRate: sampleRate,
        format: format,
        bufferCapacity: bufferCapacity,
      );
    }
    if (_isCommandAvailable('ffmpeg')) {
      return SubprocessSource.ffmpeg(
        numChannels: numChannels,
        sampleRate: sampleRate,
        format: format,
        bufferCapacity: bufferCapacity,
      );
    }
    return SubprocessSource.sox(
      numChannels: numChannels,
      sampleRate: sampleRate,
      format: format,
      bufferCapacity: bufferCapacity,
    );
  }

  static bool _isCommandAvailable(String command) {
    if (Platform.isMacOS) {
      final paths = [
        '/opt/homebrew/bin/$command',
        '/usr/local/bin/$command',
        '/usr/bin/$command',
      ];
      for (final p in paths) {
        if (File(p).existsSync()) return true;
      }
    }
    return false;
  }

  @override
  List<Inlet> get inlets => const [];

  @override
  late final List<Outlet> outlets = List.generate(
    numChannels,
    (i) => Outlet(node: this, index: i),
  );

  /// Convenience getter for the primary / mono outlet.
  Outlet get outlet => outlets.first;

  /// Convenience getter for the left channel outlet.
  Outlet get left => outlets[0];

  /// Convenience getter for the right channel outlet.
  Outlet get right => outlets[1];

  /// Convenience getter for all channel outlets.
  List<Outlet> get channels => outlets;

  @override
  SubprocessSourceProcessor createProcessor() => SubprocessSourceProcessor(
    executable: executable,
    arguments: arguments,
    numChannels: numChannels,
    format: format,
    sampleRate: sampleRate,
    bufferCapacity: bufferCapacity,
  );

  @override
  Object get params => ();

  @override
  List<AudioNodeError> get errors => [
    if (numChannels <= 0)
      const AudioNodeParamError(param: 'numChannels', error: 'must be >= 1'),
    if (executable.trim().isEmpty)
      const AudioNodeParamError(
        param: 'executable',
        error: 'must not be empty',
      ),
  ];

  @override
  List<Object?> get fixedProps => [
    executable,
    format,
    sampleRate,
    arguments,
  ];

  @override
  List<Object?> get dynamicProps => const [];
}

/// The runtime processor for [SubprocessSource].
class SubprocessSourceProcessor implements DisposableAudioProcessor {
  SubprocessSourceProcessor({
    required this.executable,
    required this.arguments,
    required this.numChannels,
    this.format = .float32,
    this.sampleRate = 44100,
    int bufferCapacity = 1048576,
  }) : _capacity = _nextPowerOfTwo(bufferCapacity),
       _mask = _nextPowerOfTwo(bufferCapacity) - 1 {
    _highWatermark = (_capacity * 0.75).toInt();
    _lowWatermark = (_capacity * 0.25).toInt();
    _ringBuffer = Uint8List(_capacity);
    _ensureStarted();
  }

  final String executable;
  final List<String> arguments;
  final int numChannels;
  final WavFormat format;
  final int sampleRate;

  final int _capacity;
  final int _mask;
  late final int _highWatermark;
  late final int _lowWatermark;
  late final Uint8List _ringBuffer;

  int _writeIndex = 0;
  int _readIndex = 0;
  int _availableBytes = 0;

  Process? _process;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  bool _isSpawning = false;
  bool _isClosed = false;
  bool _isPaused = false;
  bool _isStreamDone = false;
  Object? _startError;

  Float32List? _interleavedFloatBuffer;
  Uint8List? _interleavedFloatByteView;
  Int16List? _interleavedPcm16Buffer;
  Uint8List? _interleavedPcm16ByteView;

  /// Whether this source has been closed.
  bool get isClosed => _isClosed;

  /// The active subprocess, or null if not yet spawned or closed.
  Process? get subprocess => _process;

  /// Number of unread audio bytes currently in the ring buffer.
  int get availableBytes => _availableBytes;

  /// Whether the child process output stream has completed.
  bool get isStreamDone => _isStreamDone;

  /// The error encountered while spawning the child process, if any.
  Object? get error => _startError;

  static int _nextPowerOfTwo(int value) {
    if (value <= 1) return 1;
    int n = value - 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    return n + 1;
  }

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
          _isSpawning = false;
          _stdoutSub = p.stdout.listen(
            _onData,
            onError: (e) {
              _startError = e;
            },
            onDone: () {
              _isStreamDone = true;
            },
            cancelOnError: false,
          );
          // Drain stderr so child process does not block on full pipe buffer
          _stderrSub = p.stderr.listen((_) {});
        })
        .catchError((e) {
          _isSpawning = false;
          _startError = e;
        });
  }

  /// Ensures the child process has spawned and is ready to stream audio.
  Future<void> ensureStarted() async {
    if (_process != null) return;
    _ensureStarted();
    while (_process == null && !_isClosed && _isSpawning) {
      await Future.delayed(const Duration(milliseconds: 2));
    }
  }

  void _onData(List<int> chunk) {
    if (_isClosed) return;
    final int len = chunk.length;
    if (len == 0) return;

    final int bytesPerSample = format == .float32 ? 4 : 2;
    final int frameBytes = numChannels * bytesPerSample;

    // Drop oldest whole frames if incoming data exceeds available capacity,
    // preserving exact frame & channel byte alignment even for oversized chunks.
    int startOffset = 0;
    if (_availableBytes + len > _capacity) {
      final int overflow = (_availableBytes + len) - _capacity;
      final int framesToDrop = (overflow + frameBytes - 1) ~/ frameBytes;
      final int bytesToDrop = framesToDrop * frameBytes;
      if (bytesToDrop <= _availableBytes) {
        _availableBytes -= bytesToDrop;
        _readIndex = (_readIndex + bytesToDrop) & _mask;
      } else {
        startOffset = bytesToDrop - _availableBytes;
        _availableBytes = 0;
        _readIndex = _writeIndex;
      }
    }

    final int bytesToWrite = len - startOffset;
    if (bytesToWrite <= 0) return;

    final Uint8List data = chunk is Uint8List
        ? chunk
        : Uint8List.fromList(chunk);

    final int writeIdx = _writeIndex;
    final int toEnd = _capacity - writeIdx;
    if (bytesToWrite <= toEnd) {
      _ringBuffer.setRange(writeIdx, writeIdx + bytesToWrite, data, startOffset);
    } else {
      _ringBuffer.setRange(writeIdx, _capacity, data, startOffset);
      _ringBuffer.setRange(
        0,
        bytesToWrite - toEnd,
        data,
        startOffset + toEnd,
      );
    }
    _writeIndex = (writeIdx + bytesToWrite) & _mask;
    _availableBytes += bytesToWrite;

    // Apply backpressure if buffer exceeds high watermark
    if (!_isPaused && _availableBytes >= _highWatermark) {
      _isPaused = true;
      _stdoutSub?.pause();
    }
  }

  void _ensureBuffers(int vectorSize) {
    final int totalSamples = numChannels * vectorSize;
    if (format == .float32) {
      if (_interleavedFloatBuffer == null ||
          _interleavedFloatBuffer!.length != totalSamples) {
        _interleavedFloatBuffer = Float32List(totalSamples);
        _interleavedFloatByteView = _interleavedFloatBuffer!.buffer.asUint8List(
          _interleavedFloatBuffer!.offsetInBytes,
          _interleavedFloatBuffer!.lengthInBytes,
        );
      }
    } else {
      if (_interleavedPcm16Buffer == null ||
          _interleavedPcm16Buffer!.length != totalSamples) {
        _interleavedPcm16Buffer = Int16List(totalSamples);
        _interleavedPcm16ByteView = _interleavedPcm16Buffer!.buffer.asUint8List(
          _interleavedPcm16Buffer!.offsetInBytes,
          _interleavedPcm16Buffer!.lengthInBytes,
        );
      }
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
    _ensureStarted();
    final int vectorSize = context.vectorSize;
    if (_isClosed || _startError != null) {
      for (int ch = 0; ch < outputs.length; ch++) {
        outputs[ch].fillRange(0, vectorSize, 0.0);
      }
      return;
    }

    final int bytesPerSample = format == .float32 ? 4 : 2;
    final int frameBytes = numChannels * bytesPerSample;

    final int availableFrames = _availableBytes ~/ frameBytes;
    final int framesToRead = availableFrames < vectorSize
        ? availableFrames
        : vectorSize;
    final int bytesToRead = framesToRead * frameBytes;

    if (bytesToRead > 0) {
      _ensureBuffers(vectorSize);

      final Uint8List byteView = format == .float32
          ? _interleavedFloatByteView!
          : _interleavedPcm16ByteView!;
      final int readIdx = _readIndex;
      final int toEnd = _capacity - readIdx;

      if (bytesToRead <= toEnd) {
        byteView.setRange(0, bytesToRead, _ringBuffer, readIdx);
      } else {
        byteView.setRange(0, toEnd, _ringBuffer, readIdx);
        byteView.setRange(toEnd, bytesToRead, _ringBuffer, 0);
      }

      _readIndex = (readIdx + bytesToRead) & _mask;
      _availableBytes -= bytesToRead;

      // Resume reading if buffer dropped below low watermark
      if (_isPaused && _availableBytes <= _lowWatermark) {
        _isPaused = false;
        _stdoutSub?.resume();
      }

      // Decode and de-interleave into output channels
      if (format == .float32) {
        deinterleaveFloats(
          _interleavedFloatBuffer!,
          outputs,
          vectorSize: framesToRead,
        );
      } else {
        deinterleavePcm16(
          _interleavedPcm16Buffer!,
          outputs,
          vectorSize: framesToRead,
        );
      }
    }

    // Zero-pad remaining samples on underrun
    if (framesToRead < vectorSize) {
      for (int ch = 0; ch < outputs.length; ch++) {
        outputs[ch].fillRange(framesToRead, vectorSize, 0.0);
      }
    }
  }

  /// Closes the process and cancels subscriptions.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    try {
      await _stdoutSub?.cancel();
    } catch (_) {}
    _stdoutSub = null;
    try {
      await _stderrSub?.cancel();
    } catch (_) {}
    _stderrSub = null;
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
  }

  @override
  Future<void> dispose() async {
    await close();
  }
}
