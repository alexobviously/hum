@DefaultAsset('package:hum_codecs/src/codec_bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Native result struct populated by [humCodecsDecode] and freed by
/// [humCodecsFreeResult].
final class HumDecodedBuffer extends Struct {
  external Pointer<Float> samplesPtr;

  @Size()
  external int samplesLen;

  @Uint32()
  external int numFrames;

  @Uint32()
  external int numChannels;

  @Uint32()
  external int sampleRate;

  external Pointer<Utf8> errorPtr;
}

/// Decodes encoded audio bytes into planar 32-bit float samples via Symphonia.
///
/// Returns `0` on success and non-zero on failure. In both cases, callers must
/// release any allocated buffers in [outResult] with [humCodecsFreeResult].
@Native<
  Int32 Function(
    Pointer<Uint8>,
    Size,
    Pointer<Utf8>,
    Pointer<HumDecodedBuffer>,
  )
>(symbol: 'hum_codecs_decode')
external int humCodecsDecode(
  Pointer<Uint8> bytesPtr,
  int bytesLen,
  Pointer<Utf8> hintPtr,
  Pointer<HumDecodedBuffer> outResult,
);

/// Frees buffers allocated by [humCodecsDecode].
@Native<Void Function(Pointer<HumDecodedBuffer>)>(
  symbol: 'hum_codecs_free_result',
)
external void humCodecsFreeResult(Pointer<HumDecodedBuffer> result);
