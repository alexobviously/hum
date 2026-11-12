import 'dart:io';
import 'dart:typed_data';

/// Asynchronously writes [bytes] to a file at [path], creating parent directories if needed.
Future<void> writeBytesToFile(String path, Uint8List bytes) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
}

/// Synchronously writes [bytes] to a file at [path], creating parent directories if needed.
void writeBytesToFileSync(String path, Uint8List bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes, flush: true);
}

/// Streaming random-access file writer for [WavSink.file].
class WavFileWriter {
  final RandomAccessFile _raf;

  WavFileWriter._(this._raf);

  /// Opens [path] for writing and reserves the initial 44-byte WAV header slot.
  factory open(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final raf = file.openSync(mode: FileMode.write);
    raf.setPositionSync(44);
    return WavFileWriter._(raf);
  }

  /// Appends a block of audio [bytes] to the open WAV file.
  void writeChunk(Uint8List bytes) {
    _raf.writeFromSync(bytes);
  }

  /// Seeks back to byte 0, writes the 44-byte [header], and closes the file.
  void finalizeAndClose(Uint8List header) {
    _raf.setPositionSync(0);
    _raf.writeFromSync(header);
    _raf.closeSync();
  }
}
