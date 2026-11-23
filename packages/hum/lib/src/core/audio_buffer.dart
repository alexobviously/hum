import 'dart:typed_data';

/// Opaque, zero-cost identifier for an [AudioBuffer] stored in [AudioEngine].
extension type const BufferId(int value);

/// Lightweight, isolate-sendable metadata handle referencing an [AudioBuffer]
/// registered with an [AudioHost] / [AudioEngine].
class const BufferHandle({
  required final BufferId id,
  required final int sampleRate,
  required final int numChannels,
  required final int length,
}) {
  /// Total duration of the referenced buffer in seconds.
  double get durationSeconds => sampleRate > 0 ? length / sampleRate : 0.0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BufferHandle &&
          id == other.id &&
          sampleRate == other.sampleRate &&
          numChannels == other.numChannels &&
          length == other.length;

  @override
  int get hashCode => Object.hash(id, sampleRate, numChannels, length);

  @override
  String toString() =>
      'BufferHandle(id: $id, ${numChannels}ch, $length frames @ $sampleRate Hz)';
}

/// Planar multi-channel 32-bit float audio buffer.
///
/// Each entry in [channels] holds one channel's contiguous samples, matching
/// `hum`'s planar processing model.
class AudioBuffer({
  required final List<Float32List> channels,
  required final int sampleRate,
}) {
  this {
    if (channels.isEmpty) {
      throw ArgumentError.value(
        channels,
        'channels',
        'AudioBuffer must have at least one channel.',
      );
    }
    if (sampleRate <= 0) {
      throw ArgumentError.value(
        sampleRate,
        'sampleRate',
        'sampleRate must be positive.',
      );
    }
    final expectedLen = channels.first.length;
    for (int ch = 1; ch < channels.length; ch++) {
      if (channels[ch].length != expectedLen) {
        throw ArgumentError.value(
          channels,
          'channels',
          'All channels must have the same length '
              '(ch 0 has $expectedLen, ch $ch has ${channels[ch].length}).',
        );
      }
    }
  }

  /// Creates a single-channel [AudioBuffer].
  factory mono(Float32List samples, {required int sampleRate}) =>
      AudioBuffer(channels: [samples], sampleRate: sampleRate);

  /// Creates a stereo [AudioBuffer] from separate [left] and [right] channels.
  factory stereo(
    Float32List left,
    Float32List right, {
    required int sampleRate,
  }) => AudioBuffer(channels: [left, right], sampleRate: sampleRate);

  /// Allocates a zero-filled [AudioBuffer] of [length] frames and [numChannels].
  factory silence({
    required int length,
    required int sampleRate,
    int numChannels = 1,
  }) {
    if (numChannels <= 0) {
      throw ArgumentError.value(
        numChannels,
        'numChannels',
        'numChannels must be positive.',
      );
    }

    if (length < 0) {
      throw ArgumentError.value(
        length,
        'length',
        'length must be non-negative.',
      );
    }

    return AudioBuffer(
      channels: List.generate(
        numChannels,
        (_) => Float32List(length),
        growable: false,
      ),
      sampleRate: sampleRate,
    );
  }

  /// De-interleaves an [interleaved] multi-channel float buffer into a planar
  /// [AudioBuffer].
  factory fromInterleaved(
    Float32List interleaved, {
    required int numChannels,
    required int sampleRate,
  }) {
    if (numChannels <= 0) {
      throw ArgumentError.value(
        numChannels,
        'numChannels',
        'numChannels must be positive.',
      );
    }
    if (interleaved.length % numChannels != 0) {
      throw ArgumentError.value(
        interleaved.length,
        'interleaved',
        'Length (${interleaved.length}) must be a multiple of numChannels ($numChannels).',
      );
    }
    final frames = interleaved.length ~/ numChannels;
    final channels = List.generate(
      numChannels,
      (_) => Float32List(frames),
      growable: false,
    );
    for (int i = 0; i < frames; i++) {
      final base = i * numChannels;
      for (int ch = 0; ch < numChannels; ch++) {
        channels[ch][i] = interleaved[base + ch];
      }
    }
    return AudioBuffer(channels: channels, sampleRate: sampleRate);
  }

  /// Number of audio channels in this buffer.
  int get numChannels => channels.length;

  /// Number of sample frames per channel.
  int get length => channels.first.length;

  /// Total duration in seconds.
  double get durationSeconds => length / sampleRate;

  /// Returns the sample data for [channel].
  Float32List operator [](int channel) => channels[channel];

  @override
  String toString() =>
      'AudioBuffer(${numChannels}ch, $length frames @ $sampleRate Hz)';
}
