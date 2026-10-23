import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// A terminal audio node that captures multi-channel audio blocks and writes
/// them to a WAV file on disk or accumulates them in memory.
class WavSink extends AudioNode<WavSinkProcessor> {
  final List<Outlet> channels;
  final String? path;
  final WavFormat format;

  /// Creates a sink that writes audio directly to a file at [path].
  const WavSink.file({
    required this.channels,
    required this.path,
    this.format = .float32,
  });

  /// Creates a sink that accumulates audio blocks in memory.
  const WavSink.memory({
    required this.channels,
    this.format = .float32,
  }) : path = null;

  @override
  List<Inlet> get inlets => List.generate(
    channels.length,
    (i) => Inlet(node: this, index: i, source: channels[i]),
  );

  @override
  List<Outlet> get outlets => const [];

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
  bool canUpdate(covariant WavSink newNode) =>
      super.canUpdate(newNode) &&
      path == newNode.path &&
      channels.length == newNode.channels.length &&
      format == newNode.format;
}

/// The runtime processor for [WavSink].
class WavSinkProcessor implements AudioProcessor {
  final String? path;
  final int numChannels;
  final WavFormat format;

  WavSinkProcessor({
    this.path,
    required this.numChannels,
    this.format = .float32,
  });

  RandomAccessFile? _raf;
  BytesBuilder? _builder;
  int _sampleRate = 44100;
  int _totalDataBytes = 0;
  bool _isClosed = false;
  Uint8List? _bytes;

  Float32List? _interleavedFloats;
  Int16List? _interleavedPcm16;

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
    final totalSamples = vectorSize * numChannels;

    // Lazily open file if writing to disk
    if (path != null && _raf == null) {
      final file = File(path!);
      file.parent.createSync(recursive: true);
      final raf = file.openSync(mode: FileMode.write);
      // Reserve 44 bytes for header to be written on close()
      raf.setPositionSync(44);
      _raf = raf;
    } else if (path == null && _builder == null) {
      _builder = BytesBuilder(copy: true);
    }

    switch (format) {
      case WavFormat.float32:
        Float32List? floats = _interleavedFloats;
        if (floats == null || floats.length != totalSamples) {
          floats = Float32List(totalSamples);
          _interleavedFloats = floats;
        }

        int writeIdx = 0;
        for (int s = 0; s < vectorSize; s++) {
          for (int c = 0; c < numChannels; c++) {
            floats[writeIdx++] = inputs[c][s];
          }
        }

        final byteView = floats.buffer.asUint8List(0, totalSamples * 4);
        if (_raf != null) {
          _raf!.writeFromSync(byteView);
        } else if (_builder != null) {
          _builder!.add(byteView);
        }
        _totalDataBytes += byteView.length;

      case WavFormat.pcm16:
        Int16List? pcm16 = _interleavedPcm16;
        if (pcm16 == null || pcm16.length != totalSamples) {
          pcm16 = Int16List(totalSamples);
          _interleavedPcm16 = pcm16;
        }

        int writeIdx = 0;
        for (int s = 0; s < vectorSize; s++) {
          for (int c = 0; c < numChannels; c++) {
            final sample = inputs[c][s].clamp(-1.0, 1.0);
            pcm16[writeIdx++] = (sample * 32767.0).round();
          }
        }

        final byteView = pcm16.buffer.asUint8List(0, totalSamples * 2);
        if (_raf != null) {
          _raf!.writeFromSync(byteView);
        } else if (_builder != null) {
          _builder!.add(byteView);
        }
        _totalDataBytes += byteView.length;
    }
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

    if (_raf != null) {
      _raf!.setPositionSync(0);
      _raf!.writeFromSync(header.buffer.asUint8List(0, 44));
      _raf!.closeSync();
      _raf = null;
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
}
