import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Reads and decodes a WAV file from disk into a planar [AudioBuffer].
Future<AudioBuffer> loadWav(String path) async {
  final bytes = await File(path).readAsBytes();
  return readWav(bytes);
}

/// Synchronously reads and decodes a WAV file from disk into a planar
/// [AudioBuffer].
AudioBuffer loadWavSync(String path) => readWav(File(path).readAsBytesSync());

/// Writes audio blocks to a WAV file as 16-bit integer PCM or 32-bit float PCM.
void writeWav(
  String path,
  List<Float32List> audio, {
  int sampleRate = 44100,
  int numChannels = 1,
  WavFormat format = .float32,
}) {
  int totalSamples = 0;
  for (final block in audio) {
    totalSamples += block.length;
  }

  final bytesPerSample = format.bitsPerSample ~/ 8;
  final dataSize = totalSamples * bytesPerSample;

  final header = buildWavHeader(
    dataSize: dataSize,
    sampleRate: sampleRate,
    numChannels: numChannels,
    format: format,
  );

  final builder = BytesBuilder(copy: false);
  builder.add(header.buffer.asUint8List());

  switch (format) {
    case WavFormat.float32:
      for (final block in audio) {
        builder.add(
          block.buffer.asUint8List(block.offsetInBytes, block.lengthInBytes),
        );
      }
    case WavFormat.pcm16:
      for (final block in audio) {
        final pcm16 = Int16List(block.length);
        for (int i = 0; i < block.length; i++) {
          final sample = block[i].fastClamp(-1.0, 1.0);
          pcm16[i] = (sample * 32767.0).round();
        }
        builder.add(pcm16.buffer.asUint8List());
      }
  }

  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(builder.takeBytes(), flush: true);
}

/// Offline WAV rendering and file export extension for [AudioHost].
extension AudioHostWavExport on AudioHost {
  /// Renders [duration] of audio offline at maximum CPU speed and writes to [path]
  /// or returns the complete WAV byte buffer if [path] is null.
  Future<Uint8List> exportWav({
    String? path,
    required Duration duration,
    WavFormat format = .float32,
  }) async {
    if (numChannels == 0) {
      throw StateError(
        'No active audio graph to export. Call setGraph() first.',
      );
    }
    final sampleRate = context.sampleRate;
    final vectorSize = context.vectorSize;
    final totalSamples = (sampleRate * duration.inMicroseconds) ~/ 1000000;
    final totalBlocks = (totalSamples + vectorSize - 1) ~/ vectorSize;

    final interleaver = BufferInterleaver(
      numChannels: numChannels,
      vectorSize: vectorSize,
    );
    // Must copy: `interleaver` reuses a single scratch buffer across blocks.
    final builder = BytesBuilder();

    if (this case final SyncAudioHost syncHost) {
      for (int i = 0; i < totalBlocks; i++) {
        syncHost.process();
        final byteView = switch (format) {
          .float32 => interleaver.interleaveFloat32Bytes(syncHost.outputs),
          .pcm16 => interleaver.interleavePcm16Bytes(syncHost.outputs),
        };
        builder.add(byteView);
      }
    } else {
      final renderedBlocks = await renderBlocks(totalBlocks);
      for (int i = 0; i < totalBlocks; i++) {
        final blockChannels = <Float32List>[
          for (int ch = 0; ch < numChannels; ch++)
            renderedBlocks[i * numChannels + ch],
        ];
        final byteView = switch (format) {
          .float32 => interleaver.interleaveFloat32Bytes(blockChannels),
          .pcm16 => interleaver.interleavePcm16Bytes(blockChannels),
        };
        builder.add(byteView);
      }
    }

    final dataBytes = builder.takeBytes();
    final header = buildWavHeader(
      dataSize: dataBytes.length,
      sampleRate: sampleRate,
      numChannels: numChannels,
      format: format,
    );

    final wavFileBytes = BytesBuilder(copy: false);
    wavFileBytes.add(header.buffer.asUint8List(0, 44));
    wavFileBytes.add(dataBytes);
    final completeWav = wavFileBytes.takeBytes();

    if (path != null) {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(completeWav, flush: true);
    }

    return completeWav;
  }
}
