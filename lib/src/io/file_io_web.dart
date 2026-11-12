import 'dart:typed_data';

/// Web stub for [WavFileWriter]; throws [UnsupportedError].
class WavFileWriter {
  factory WavFileWriter.open(String path) {
    throw UnsupportedError(
      'WavSink.file("$path") is not supported on Web. Use WavSink.memory() instead.',
    );
  }

  void writeChunk(Uint8List bytes) {}

  void finalizeAndClose(Uint8List header) {}
}
