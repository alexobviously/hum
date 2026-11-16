import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'cpal_bindings.dart';

/// Audio sample format supported by a cpal stream configuration.
enum CpalSampleFormat {
  f32,
  f64,
  i16,
  i32,
  u16,
  other;

  /// Parses the serialized format identifier emitted by Rust.
  factory fromWire(String value) => switch (value) {
    'f32' => f32,
    'f64' => f64,
    'i16' => i16,
    'i32' => i32,
    'u16' => u16,
    _ => other,
  };
}

/// Inclusive frame buffer size range supported by a stream configuration.
class const CpalBufferSizeRange({
  required final int min,
  required final int max,
}) {
  /// Decodes a [CpalBufferSizeRange] from a JSON map.
  factory fromJson(Map<String, Object?> json) => CpalBufferSizeRange(
    min: json['min'] as int,
    max: json['max'] as int,
  );

  @override
  String toString() => min == max ? '$min frames' : '$min..$max frames';
}

/// Default stream configuration reported for a device direction.
class const CpalDefaultConfig({
  required final int sampleRate,
  required final int channels,
  required final CpalSampleFormat sampleFormat,
  final CpalBufferSizeRange? bufferSize,
}) {
  /// Decodes a [CpalDefaultConfig] from a JSON map.
  factory fromJson(Map<String, Object?> json) => CpalDefaultConfig(
    sampleRate: json['sampleRate'] as int,
    channels: json['channels'] as int,
    sampleFormat: CpalSampleFormat.fromWire(json['sampleFormat'] as String),
    bufferSize: switch (json['bufferSize']) {
      final Map<String, Object?> map => CpalBufferSizeRange.fromJson(map),
      _ => null,
    },
  );

  @override
  String toString() =>
      '${sampleRate}Hz ${channels}ch ${sampleFormat.name}'
      '${bufferSize != null ? ' ($bufferSize)' : ''}';
}

/// Range of stream configurations supported by a device direction.
class const CpalConfigRange({
  required final int channels,
  required final int minSampleRate,
  required final int maxSampleRate,
  required final CpalSampleFormat sampleFormat,
  final CpalBufferSizeRange? bufferSize,
}) {
  /// Decodes a [CpalConfigRange] from a JSON map.
  factory fromJson(Map<String, Object?> json) => CpalConfigRange(
    channels: json['channels'] as int,
    minSampleRate: json['minSampleRate'] as int,
    maxSampleRate: json['maxSampleRate'] as int,
    sampleFormat: CpalSampleFormat.fromWire(json['sampleFormat'] as String),
    bufferSize: switch (json['bufferSize']) {
      final Map<String, Object?> map => CpalBufferSizeRange.fromJson(map),
      _ => null,
    },
  );

  @override
  String toString() =>
      '${channels}ch $minSampleRate..${maxSampleRate}Hz ${sampleFormat.name}'
      '${bufferSize != null ? ' ($bufferSize)' : ''}';
}

/// Capabilities and identity for a single host audio device.
class const CpalDeviceInfo({
  required final String id,
  required final String name,
  required final bool isDefaultOutput,
  required final bool isDefaultInput,
  final CpalDefaultConfig? defaultOutput,
  final CpalDefaultConfig? defaultInput,
  required final List<CpalConfigRange> outputConfigs,
  required final List<CpalConfigRange> inputConfigs,
}) {
  /// Decodes a [CpalDeviceInfo] from a JSON map.
  factory fromJson(Map<String, Object?> json) => CpalDeviceInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    isDefaultOutput: json['isDefaultOutput'] as bool,
    isDefaultInput: json['isDefaultInput'] as bool,
    defaultOutput: switch (json['defaultOutput']) {
      final Map<String, Object?> map => CpalDefaultConfig.fromJson(map),
      _ => null,
    },
    defaultInput: switch (json['defaultInput']) {
      final Map<String, Object?> map => CpalDefaultConfig.fromJson(map),
      _ => null,
    },
    outputConfigs: [
      for (final item in json['outputConfigs'] as List<Object?>)
        CpalConfigRange.fromJson(item as Map<String, Object?>),
    ],
    inputConfigs: [
      for (final item in json['inputConfigs'] as List<Object?>)
        CpalConfigRange.fromJson(item as Map<String, Object?>),
    ],
  );
}

/// Snapshot of the default cpal audio host and its enumerated devices.
class const CpalHostSnapshot({
  required final String hostName,
  required final List<CpalDeviceInfo> devices,
}) {
  /// Decodes a [CpalHostSnapshot] from a JSON map.
  factory fromJson(Map<String, Object?> json) => CpalHostSnapshot(
    hostName: json['hostName'] as String,
    devices: [
      for (final item in json['devices'] as List<Object?>)
        CpalDeviceInfo.fromJson(item as Map<String, Object?>),
    ],
  );

  /// Queries the default cpal host for all currently connected audio devices.
  static CpalHostSnapshot probe() {
    final ptr = humCpalProbeDevicesJson();
    if (ptr == nullptr) {
      throw StateError('Failed to probe cpal audio devices.');
    }
    final String jsonText;
    try {
      jsonText = ptr.toDartString();
    } finally {
      humCpalFreeString(ptr);
    }
    return CpalHostSnapshot.fromJson(
      jsonDecode(jsonText) as Map<String, Object?>,
    );
  }

  /// The host's default output device, if one is available.
  CpalDeviceInfo? get defaultOutputDevice {
    for (final device in devices) {
      if (device.isDefaultOutput) return device;
    }
    return null;
  }

  /// The host's default input device, if one is available.
  CpalDeviceInfo? get defaultInputDevice {
    for (final device in devices) {
      if (device.isDefaultInput) return device;
    }
    return null;
  }
}
