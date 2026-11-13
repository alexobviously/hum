// Copyright (c) 2026, the hum authors. All rights reserved.
// Please see the AUTHORS file for details. Use of this source code is governed
// by a BSD-style license that can be found in the LICENSE file.

// Keep only the low-level device I/O and ring buffer modules of miniaudio.
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_WAV
#define MA_NO_FLAC
#define MA_NO_MP3
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_NO_GENERATION

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "hum_miniaudio.h"

#include <stdlib.h>
#include <string.h>

struct hum_ma_playback {
  ma_device device;
  ma_pcm_rb rb;
  ma_uint32 channels;
  ma_atomic_bool32 device_stopped;
  ma_atomic_bool32 closing;
};

static void hum_ma_data_callback(
    ma_device* device,
    void* output,
    const void* input,
    ma_uint32 frame_count) {
  (void)input;

  hum_ma_playback_t* handle = (hum_ma_playback_t*)device->pUserData;
  if (handle == NULL || output == NULL || frame_count == 0) {
    return;
  }

  float* dst = (float*)output;
  const ma_uint32 channels = handle->channels;

  if (ma_atomic_bool32_get(&handle->closing) ||
      ma_atomic_bool32_get(&handle->device_stopped)) {
    memset(dst, 0, (size_t)frame_count * channels * sizeof(float));
    return;
  }

  ma_uint32 frames_read = 0;
  while (frames_read < frame_count) {
    ma_uint32 chunk = frame_count - frames_read;
    void* rb_ptr = NULL;
    ma_result res = ma_pcm_rb_acquire_read(&handle->rb, &chunk, &rb_ptr);
    if ((res != MA_SUCCESS && res != MA_AT_END) || chunk == 0 ||
        rb_ptr == NULL) {
      break;
    }

    memcpy(
        dst + (size_t)frames_read * channels,
        rb_ptr,
        (size_t)chunk * channels * sizeof(float));
    ma_pcm_rb_commit_read(&handle->rb, chunk);
    frames_read += chunk;
  }

  if (frames_read < frame_count) {
    memset(
        dst + (size_t)frames_read * channels,
        0,
        (size_t)(frame_count - frames_read) * channels * sizeof(float));
  }
}

static void hum_ma_notification_callback(
    const ma_device_notification* notification) {
  if (notification == NULL || notification->pDevice == NULL) {
    return;
  }

  hum_ma_playback_t* handle =
      (hum_ma_playback_t*)notification->pDevice->pUserData;
  if (handle != NULL &&
      notification->type == ma_device_notification_type_stopped &&
      !ma_atomic_bool32_get(&handle->closing)) {
    ma_atomic_bool32_set(&handle->device_stopped, MA_TRUE);
  }
}

HUM_MA_API const char* hum_ma_version_string(void) {
  return ma_version_string();
}

HUM_MA_API const char* hum_ma_result_description(int32_t result) {
  return ma_result_description((ma_result)result);
}

HUM_MA_API int32_t hum_ma_playback_create(
    uint32_t sample_rate,
    uint32_t channels,
    uint32_t buffer_frames,
    hum_ma_playback_t** out_handle) {
  if (out_handle == NULL) {
    return MA_INVALID_ARGS;
  }
  *out_handle = NULL;

  if (sample_rate == 0 || channels == 0 || buffer_frames == 0) {
    return MA_INVALID_ARGS;
  }

  hum_ma_playback_t* handle =
      (hum_ma_playback_t*)calloc(1, sizeof(hum_ma_playback_t));
  if (handle == NULL) {
    return MA_OUT_OF_MEMORY;
  }

  handle->channels = channels;
  ma_atomic_bool32_set(&handle->device_stopped, MA_FALSE);
  ma_atomic_bool32_set(&handle->closing, MA_FALSE);

  ma_result res = ma_pcm_rb_init(
      ma_format_f32,
      channels,
      buffer_frames,
      NULL,
      NULL,
      &handle->rb);
  if (res != MA_SUCCESS) {
    free(handle);
    return res;
  }

  ma_device_config config = ma_device_config_init(ma_device_type_playback);
  config.playback.format = ma_format_f32;
  config.playback.channels = channels;
  config.sampleRate = sample_rate;
  config.dataCallback = hum_ma_data_callback;
  config.notificationCallback = hum_ma_notification_callback;
  config.pUserData = handle;

  res = ma_device_init(NULL, &config, &handle->device);
  if (res != MA_SUCCESS) {
    ma_pcm_rb_uninit(&handle->rb);
    free(handle);
    return res;
  }

  res = ma_device_start(&handle->device);
  if (res != MA_SUCCESS) {
    ma_device_uninit(&handle->device);
    ma_pcm_rb_uninit(&handle->rb);
    free(handle);
    return res;
  }

  *out_handle = handle;
  return MA_SUCCESS;
}

HUM_MA_API uint32_t hum_ma_playback_available_write(hum_ma_playback_t* handle) {
  if (handle == NULL || ma_atomic_bool32_get(&handle->closing)) {
    return 0;
  }
  return ma_pcm_rb_available_write(&handle->rb);
}

HUM_MA_API uint32_t hum_ma_playback_write(
    hum_ma_playback_t* handle,
    const float* interleaved_frames,
    uint32_t frame_count) {
  if (handle == NULL || interleaved_frames == NULL || frame_count == 0 ||
      ma_atomic_bool32_get(&handle->closing) ||
      ma_atomic_bool32_get(&handle->device_stopped)) {
    return 0;
  }

  const ma_uint32 channels = handle->channels;
  ma_uint32 frames_written = 0;

  while (frames_written < frame_count) {
    ma_uint32 chunk = frame_count - frames_written;
    void* rb_ptr = NULL;
    ma_result res = ma_pcm_rb_acquire_write(&handle->rb, &chunk, &rb_ptr);
    if ((res != MA_SUCCESS && res != MA_AT_END) || chunk == 0 ||
        rb_ptr == NULL) {
      break;
    }

    memcpy(
        rb_ptr,
        interleaved_frames + (size_t)frames_written * channels,
        (size_t)chunk * channels * sizeof(float));
    ma_pcm_rb_commit_write(&handle->rb, chunk);
    frames_written += chunk;
  }

  return frames_written;
}

HUM_MA_API bool hum_ma_playback_is_stopped(hum_ma_playback_t* handle) {
  if (handle == NULL) {
    return true;
  }
  return ma_atomic_bool32_get(&handle->device_stopped) == MA_TRUE;
}

HUM_MA_API void hum_ma_playback_close(hum_ma_playback_t* handle) {
  if (handle == NULL) {
    return;
  }

  ma_atomic_bool32_set(&handle->closing, MA_TRUE);
  ma_device_uninit(&handle->device);
  ma_pcm_rb_uninit(&handle->rb);
  free(handle);
}
