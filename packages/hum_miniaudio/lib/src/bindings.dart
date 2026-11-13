@DefaultAsset('package:hum_miniaudio/src/bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Opaque handle representing a native miniaudio playback device and ring buffer.
final class HumMaPlayback extends Opaque {}

@Native<Pointer<Utf8> Function()>(isLeaf: true, symbol: 'hum_ma_version_string')
external Pointer<Utf8> humMaVersionString();

@Native<Pointer<Utf8> Function(Int32)>(
  isLeaf: true,
  symbol: 'hum_ma_result_description',
)
external Pointer<Utf8> humMaResultDescription(int result);

@Native<
  Int32 Function(Uint32, Uint32, Uint32, Pointer<Pointer<HumMaPlayback>>)
>(symbol: 'hum_ma_playback_create')
external int humMaPlaybackCreate(
  int sampleRate,
  int channels,
  int bufferFrames,
  Pointer<Pointer<HumMaPlayback>> outHandle,
);

@Native<Uint32 Function(Pointer<HumMaPlayback>)>(
  isLeaf: true,
  symbol: 'hum_ma_playback_available_write',
)
external int humMaPlaybackAvailableWrite(Pointer<HumMaPlayback> handle);

@Native<Uint32 Function(Pointer<HumMaPlayback>, Pointer<Float>, Uint32)>(
  isLeaf: true,
  symbol: 'hum_ma_playback_write',
)
external int humMaPlaybackWrite(
  Pointer<HumMaPlayback> handle,
  Pointer<Float> interleavedFrames,
  int frameCount,
);

@Native<Bool Function(Pointer<HumMaPlayback>)>(
  isLeaf: true,
  symbol: 'hum_ma_playback_is_stopped',
)
external bool humMaPlaybackIsStopped(Pointer<HumMaPlayback> handle);

@Native<Void Function(Pointer<HumMaPlayback>)>(symbol: 'hum_ma_playback_close')
external void humMaPlaybackClose(Pointer<HumMaPlayback> handle);

