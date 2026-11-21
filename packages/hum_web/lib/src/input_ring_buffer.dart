import 'dart:typed_data';

/// Fixed-capacity interleaved `Float32` circular buffer used by
/// `WebAudioInputDriver` to decouple `MessagePort` delivery from fixed-size
/// `AudioEngine` reads.
class InputRingBuffer({
  required final int numChannels,
  required final int capacityFrames,
}) {
  late final Float32List _buffer = Float32List(capacityFrames * numChannels);
  int _readFrame = 0;
  int _writeFrame = 0;
  int _availableFrames = 0;
  int _overruns = 0;
  int _underruns = 0;

  this
    : assert(numChannels > 0, 'numChannels must be positive'),
      assert(capacityFrames > 0, 'capacityFrames must be positive');

  /// Number of complete frames currently buffered and ready to read.
  int get availableFrames => _availableFrames;

  /// Number of write calls that dropped frames because the buffer was full.
  int get overruns => _overruns;

  /// Number of read calls that had fewer than the requested frames available.
  int get underruns => _underruns;

  /// Appends [frames] interleaved frames from [data] into the ring buffer.
  ///
  /// If the buffer does not have enough free space, oldest buffered frames are
  /// dropped to keep latency bounded and [overruns] is incremented.
  void pushInterleaved(Float32List data, int frames) {
    if (frames <= 0) return;

    int srcFrame = 0;
    int toWrite = frames;

    if (toWrite > capacityFrames) {
      // More frames than total capacity: keep only the newest capacityFrames.
      srcFrame = toWrite - capacityFrames;
      toWrite = capacityFrames;
      _readFrame = 0;
      _writeFrame = 0;
      _availableFrames = 0;
      _overruns++;
    } else if (_availableFrames + toWrite > capacityFrames) {
      // Advance read pointer to drop the oldest frames so newest audio fits.
      final drop = (_availableFrames + toWrite) - capacityFrames;
      _readFrame = (_readFrame + drop) % capacityFrames;
      _availableFrames -= drop;
      _overruns++;
    }

    final firstFrames = capacityFrames - _writeFrame;
    final chunk1 = toWrite < firstFrames ? toWrite : firstFrames;
    final chunk1Samples = chunk1 * numChannels;
    _buffer.setRange(
      _writeFrame * numChannels,
      _writeFrame * numChannels + chunk1Samples,
      data,
      srcFrame * numChannels,
    );
    _writeFrame = (_writeFrame + chunk1) % capacityFrames;

    final chunk2 = toWrite - chunk1;
    if (chunk2 > 0) {
      final chunk2Samples = chunk2 * numChannels;
      _buffer.setRange(
        0,
        chunk2Samples,
        data,
        (srcFrame + chunk1) * numChannels,
      );
      _writeFrame = chunk2;
    }

    _availableFrames += toWrite;
  }

  /// Reads [frames] interleaved frames into [target], zero-filling any
  /// shortfall and incrementing [underruns] if fewer than [frames] are ready.
  void popInterleaved(Float32List target, int frames) {
    final toRead = _availableFrames < frames ? _availableFrames : frames;

    if (toRead > 0) {
      final firstFrames = capacityFrames - _readFrame;
      final chunk1 = toRead < firstFrames ? toRead : firstFrames;
      final chunk1Samples = chunk1 * numChannels;
      target.setRange(0, chunk1Samples, _buffer, _readFrame * numChannels);
      _readFrame = (_readFrame + chunk1) % capacityFrames;

      final chunk2 = toRead - chunk1;
      if (chunk2 > 0) {
        final chunk2Samples = chunk2 * numChannels;
        target.setRange(chunk1Samples, chunk1Samples + chunk2Samples, _buffer);
        _readFrame = chunk2;
      }

      _availableFrames -= toRead;
    }

    if (toRead < frames) {
      _underruns++;
      target.fillRange(toRead * numChannels, frames * numChannels, 0.0);
    }
  }

  /// Clears all buffered audio without reallocating storage.
  void clear() {
    _readFrame = 0;
    _writeFrame = 0;
    _availableFrames = 0;
  }
}
