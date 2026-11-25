import 'dart:js_interop';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:web/web.dart' as web;

/// Decodes an encoded audio byte buffer into a planar 32-bit float [AudioBuffer]
/// using the browser's built-in Web Audio `AudioContext.decodeAudioData`.
///
/// The optional [hint] parameter is accepted for API parity with native
/// decoders (browsers sniff container/codec headers automatically).
Future<AudioBuffer> decodeAudio(Uint8List bytes, {String? hint}) async {
  if (bytes.isEmpty) {
    throw const FormatException('Input audio buffer is empty.');
  }

  // `decodeAudioData` detaches the ArrayBuffer it receives, so copy into a
  // fresh buffer to avoid neutering the caller's `Uint8List`.
  final copy = Uint8List.fromList(bytes);
  final ctx = web.AudioContext();
  try {
    final jsBuffer = await ctx.decodeAudioData(copy.buffer.toJS).toDart;
    final numChannels = jsBuffer.numberOfChannels;
    final sampleRate = jsBuffer.sampleRate.round();
    final channels = List<Float32List>.generate(
      numChannels,
      (ch) => Float32List.fromList(jsBuffer.getChannelData(ch).toDart),
      growable: false,
    );
    return AudioBuffer(channels: channels, sampleRate: sampleRate);
  } catch (e) {
    throw FormatException('Failed to decode audio in browser: $e');
  } finally {
    try {
      await ctx.close().toDart;
    } catch (_) {}
  }
}
