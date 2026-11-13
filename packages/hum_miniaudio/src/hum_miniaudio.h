// Copyright (c) 2026, the hum authors. All rights reserved.
// Please see the AUTHORS file for details. Use of this source code is governed
// by a BSD-style license that can be found in the LICENSE file.

#ifndef HUM_MINIAUDIO_H_
#define HUM_MINIAUDIO_H_

#include <stdbool.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(HUM_MINIAUDIO_EXPORTS)
#define HUM_MA_API __declspec(dllexport)
#else
#define HUM_MA_API __declspec(dllimport)
#endif
#elif defined(__GNUC__) && __GNUC__ >= 4
#define HUM_MA_API __attribute__((visibility("default")))
#else
#define HUM_MA_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to an active miniaudio playback device and its backing
/// lock-free ring buffer.
typedef struct hum_ma_playback hum_ma_playback_t;

/// Returns the bundled miniaudio library version string.
HUM_MA_API const char* hum_ma_version_string(void);

/// Returns a human-readable description for a miniaudio result code.
HUM_MA_API const char* hum_ma_result_description(int32_t result);

/// Opens and starts a float32 playback device backed by a ring buffer.
///
/// Returns `0` (`MA_SUCCESS`) on success or a negative miniaudio error code.
HUM_MA_API int32_t hum_ma_playback_create(
    uint32_t sample_rate,
    uint32_t channels,
    uint32_t buffer_frames,
    hum_ma_playback_t** out_handle);

/// Returns the number of float32 frames currently available to write.
HUM_MA_API uint32_t hum_ma_playback_available_write(hum_ma_playback_t* handle);

/// Writes up to [frame_count] interleaved float32 frames to the ring buffer.
///
/// Returns the number of frames actually written.
HUM_MA_API uint32_t hum_ma_playback_write(
    hum_ma_playback_t* handle,
    const float* interleaved_frames,
    uint32_t frame_count);

/// Returns whether the playback device stopped unexpectedly.
HUM_MA_API bool hum_ma_playback_is_stopped(hum_ma_playback_t* handle);

/// Stops the playback device, joins the audio thread, and frees [handle].
HUM_MA_API void hum_ma_playback_close(hum_ma_playback_t* handle);

#ifdef __cplusplus
}
#endif

#endif  // HUM_MINIAUDIO_H_
