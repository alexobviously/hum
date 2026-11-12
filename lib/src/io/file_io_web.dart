import 'dart:typed_data';

/// Web stub for [writeBytesToFile]; throws [UnsupportedError].
Future<void> writeBytesToFile(String path, Uint8List bytes) {
  throw UnsupportedError(
    'Writing directly to a filesystem path ("$path") is not supported on Web. '
    'Omit path to receive the WAV bytes in memory as a Uint8List.',
  );
}

/// Web stub for [writeBytesToFileSync]; throws [UnsupportedError].
void writeBytesToFileSync(String path, Uint8List bytes) {
  throw UnsupportedError(
    'Writing directly to a filesystem path ("$path") is not supported on Web. '
    'Use buildWavHeader / exportWav(duration: ...) in memory instead.',
  );
}

/// Web stub for [WavFileWriter]; throws [UnsupportedError].
class WavFileWriter {
  factory open(String path) {
    throw UnsupportedError(
      'WavSink.file("$path") is not supported on Web. Use WavSink.memory() instead.',
    );
  }

  void writeChunk(Uint8List bytes) {}

  void finalizeAndClose(Uint8List header) {}
}
