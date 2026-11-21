import 'dart:typed_data';

import 'package:hum/hum.dart';
import '../../io/file_io.dart';

/// A terminal audio node that captures multi-channel audio blocks and writes
/// them to a WAV file on disk or accumulates them in memory.
class WavSink extends TerminalNode<WavSinkProcessor> {
  final List<Outlet> channels;
  final String? path;
  final WavFormat format;

  /// Creates a sink that writes audio directly to a file at [path].
  WavSink.file({
    required this.channels,
    required this.path,
    this.format = .float32,
  });

  /// Creates a sink that accumulates audio blocks in memory.
  WavSink.memory({
    required this.channels,
    this.format = .float32,
  }) : path = null;

  @override
  List<Inlet> get inlets => List.generate(
    channels.length,
    (i) => Inlet(node: this, index: i, source: channels[i]),
  );

  @override
  WavSinkProcessor createProcessor() => WavSinkProcessor(
    path: path,
    numChannels: channels.length,
    format: format,
  );

  @override
  Object get params => ();

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeParamError(param: 'channels', error: 'must not be empty'),
  ];

  @override
  List<Object?> get fixedProps => [path, format];

  @override
  List<Object?> get dynamicProps => const [];
}

/// The runtime processor for [WavSink].
class WavSinkProcessor implements DisposableAudioProcessor {
  final String? path;
  final int numChannels;
  final WavFormat format;

  WavSinkProcessor({
    this.path,
    required this.numChannels,
    this.format = .float32,
  });

  WavFileWriter? _fileWriter;
  BytesBuilder? _builder;
  int _sampleRate = 44100;
  int _totalDataBytes = 0;
  bool _isClosed = false;
  Uint8List? _bytes;

  BufferInterleaver? _interleaver;

  /// Whether this sink has been closed.
  bool get isClosed => _isClosed;

  /// Returns the complete WAV file bytes in memory mode (closing the sink if needed).
  Uint8List? get bytes {
    if (_bytes != null) return _bytes;
    if (!_isClosed && path == null) {
      return close();
    }
    return null;
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

    _sampleRate = context.sampleRate;
    final vectorSize = context.vectorSize;

    // Lazily open file if writing to disk
    if (path != null && _fileWriter == null) {
      _fileWriter = WavFileWriter.open(path!);
    } else if (path == null && _builder == null) {
      _builder = BytesBuilder(copy: true);
    }

    BufferInterleaver? interleaver = _interleaver;
    if (interleaver == null || interleaver.vectorSize != vectorSize) {
      interleaver = _interleaver = BufferInterleaver(
        numChannels: numChannels,
        vectorSize: vectorSize,
      );
    }

    final byteView = switch (format) {
      WavFormat.float32 => interleaver.interleaveFloat32Bytes(inputs),
      WavFormat.pcm16 => interleaver.interleavePcm16Bytes(inputs),
    };

    if (_fileWriter != null) {
      _fileWriter!.writeChunk(byteView);
    } else if (_builder != null) {
      _builder!.add(byteView);
    }
    _totalDataBytes += byteView.length;
  }

  /// Finalizes the WAV header, closes file handles, and returns the complete
  /// WAV file as [Uint8List] if in memory mode.
  Uint8List? close() {
    if (_isClosed) return _bytes;
    _isClosed = true;

    final header = buildWavHeader(
      dataSize: _totalDataBytes,
      sampleRate: _sampleRate,
      numChannels: numChannels,
      format: format,
    );

    if (_fileWriter != null) {
      _fileWriter!.finalizeAndClose(header.buffer.asUint8List(0, 44));
      _fileWriter = null;
      return null;
    }

    if (_builder != null) {
      final fullBytes = BytesBuilder(copy: false);
      fullBytes.add(header.buffer.asUint8List(0, 44));
      fullBytes.add(_builder!.takeBytes());
      _bytes = fullBytes.takeBytes();
      return _bytes;
    }

    _bytes = header.buffer.asUint8List(0, 44);
    return _bytes;
  }

  @override
  void dispose() {
    close();
  }
}
