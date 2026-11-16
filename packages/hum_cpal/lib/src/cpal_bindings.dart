@DefaultAsset('package:hum_cpal/src/cpal_bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Opaque handle representing an active Rust cpal playback stream.
final class HumPlaybackHandle extends Opaque;

/// Probes the default cpal host and returns a UTF-8 JSON string pointer.
///
/// Callers must free non-null pointers with [humCpalFreeString].
@Native<Pointer<Utf8> Function()>(symbol: 'hum_cpal_probe_devices_json')
external Pointer<Utf8> humCpalProbeDevicesJson();

/// Frees a Rust-allocated UTF-8 string returned by native `hum_cpal` calls.
@Native<Void Function(Pointer<Utf8>)>(symbol: 'hum_cpal_free_string')
external void humCpalFreeString(Pointer<Utf8> ptr);

/// Opens and starts a float32 cpal output stream backed by an `rtrb` buffer.
///
/// Passing `nullptr` for [deviceId] selects the host's default output device.
/// On failure returns `nullptr` and writes an error string to [outError]
/// (which callers must free via [humCpalFreeString]).
@Native<
  Pointer<HumPlaybackHandle> Function(
    Pointer<Utf8>,
    Uint32,
    Uint32,
    Uint32,
    Pointer<Pointer<Utf8>>,
  )
>(symbol: 'hum_cpal_playback_create')
external Pointer<HumPlaybackHandle> humCpalPlaybackCreate(
  Pointer<Utf8> deviceId,
  int sampleRate,
  int channels,
  int bufferFrames,
  Pointer<Pointer<Utf8>> outError,
);

/// Returns the number frames available to write.
/// A frame is 1 sample per channel, e.g. in stereo it is [L, R].
/// Frames are interleaved float32.
@Native<Uint32 Function(Pointer<HumPlaybackHandle>)>(
  isLeaf: true,
  symbol: 'hum_cpal_playback_available_write',
)
external int humCpalPlaybackAvailableWrite(Pointer<HumPlaybackHandle> handle);

/// Writes up to [frames] interleaved float32 frames into the ring buffer.
@Native<Uint32 Function(Pointer<HumPlaybackHandle>, Pointer<Float>, Uint32)>(
  isLeaf: true,
  symbol: 'hum_cpal_playback_write',
)
external int humCpalPlaybackWrite(
  Pointer<HumPlaybackHandle> handle,
  Pointer<Float> data,
  int frames,
);

/// Returns whether the stream has stopped due to a device error or null handle.
@Native<Bool Function(Pointer<HumPlaybackHandle>)>(
  isLeaf: true,
  symbol: 'hum_cpal_playback_is_stopped',
)
external bool humCpalPlaybackIsStopped(Pointer<HumPlaybackHandle> handle);

/// Takes and clears the last stream error message, if any.
///
/// Callers must free non-null pointers with [humCpalFreeString].
@Native<Pointer<Utf8> Function(Pointer<HumPlaybackHandle>)>(
  symbol: 'hum_cpal_playback_take_error',
)
external Pointer<Utf8> humCpalPlaybackTakeError(
  Pointer<HumPlaybackHandle> handle,
);

/// Returns the total hardware callback underrun count observed so far.
@Native<Uint64 Function(Pointer<HumPlaybackHandle>)>(
  isLeaf: true,
  symbol: 'hum_cpal_playback_underruns',
)
external int humCpalPlaybackUnderruns(Pointer<HumPlaybackHandle> handle);

/// Stops the playback stream and frees all associated Rust resources.
@Native<Void Function(Pointer<HumPlaybackHandle>)>(
  symbol: 'hum_cpal_playback_close',
)
external void humCpalPlaybackClose(Pointer<HumPlaybackHandle> handle);
