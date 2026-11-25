import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:hum/hum.dart';

import 'codec_bindings.dart';

/// Synchronously decodes an encoded audio byte buffer into a planar 32-bit
/// float [AudioBuffer] via Rust Symphonia over Dart FFI.
///
/// Pass an optional file extension [hint] (e.g. `'mp3'`, `'flac'`, `'ogg'`)
/// to assist format probing.
///
/// Throws [FormatException] if the data cannot be decoded.
AudioBuffer decodeAudioSync(Uint8List bytes, {String? hint}) {
  if (bytes.isEmpty) {
    throw const FormatException('Input audio buffer is empty.');
  }

  final bytesPtr = calloc<Uint8>(bytes.length);
  final hintPtr = hint != null ? hint.toNativeUtf8() : nullptr;
  final resultPtr = calloc<HumDecodedBuffer>();

  try {
    bytesPtr.asTypedList(bytes.length).setAll(0, bytes);

    final rc = humCodecsDecode(bytesPtr, bytes.length, hintPtr, resultPtr);
    final result = resultPtr.ref;

    if (rc != 0) {
      final message = result.errorPtr != nullptr
          ? result.errorPtr.toDartString()
          : 'Native audio decode failed (code $rc).';
      throw FormatException(message);
    }

    final numChannels = result.numChannels;
    final numFrames = result.numFrames;
    final sampleRate = result.sampleRate;

    if (numChannels == 0 || sampleRate == 0) {
      throw const FormatException('Decoded audio contained no valid channels.');
    }

    if (numFrames == 0 || result.samplesPtr == nullptr) {
      return AudioBuffer.silence(
        length: 0,
        sampleRate: sampleRate,
        numChannels: numChannels,
      );
    }

    final totalSamples = numChannels * numFrames;
    final nativeFlat = result.samplesPtr.asTypedList(totalSamples);
    final channels = List<Float32List>.generate(
      numChannels,
      (ch) {
        final start = ch * numFrames;
        return Float32List.fromList(
          nativeFlat.sublist(start, start + numFrames),
        );
      },
      growable: false,
    );

    return AudioBuffer(channels: channels, sampleRate: sampleRate);
  } finally {
    humCodecsFreeResult(resultPtr);
    calloc.free(resultPtr);
    if (hintPtr != nullptr) {
      calloc.free(hintPtr);
    }
    calloc.free(bytesPtr);
  }
}

/// Asynchronously decodes an encoded audio byte buffer into a planar 32-bit
/// float [AudioBuffer] on a background isolate so UI threads never jank.
///
/// Pass an optional file extension [hint] (e.g. `'mp3'`, `'flac'`, `'ogg'`)
/// to assist format probing.
Future<AudioBuffer> decodeAudio(Uint8List bytes, {String? hint}) {
  if (bytes.isEmpty) {
    return Future<AudioBuffer>.error(
      const FormatException('Input audio buffer is empty.'),
    );
  }
  return Isolate.run(() => decodeAudioSync(bytes, hint: hint));
}

/// Reads an audio file from [path] and decodes it asynchronously on a
/// background isolate into a planar [AudioBuffer].
Future<AudioBuffer> loadAudio(String path) async {
  final bytes = await File(path).readAsBytes();
  return decodeAudio(bytes, hint: _extensionHint(path));
}

/// Synchronously reads and decodes an audio file from [path] into a planar
/// [AudioBuffer].
AudioBuffer loadAudioSync(String path) {
  final bytes = File(path).readAsBytesSync();
  return decodeAudioSync(bytes, hint: _extensionHint(path));
}

String? _extensionHint(String path) {
  final lastSlash = path.lastIndexOf('/');
  final lastBackslash = path.lastIndexOf('\\');
  final sep = lastSlash > lastBackslash ? lastSlash : lastBackslash;
  final dot = path.lastIndexOf('.');
  if (dot <= sep + 1 || dot == path.length - 1) return null;
  return path.substring(dot + 1).toLowerCase();
}
