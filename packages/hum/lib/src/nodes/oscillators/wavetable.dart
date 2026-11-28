import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Minimum table length for the top octave mipmap level (pure fundamental).
const int _minMipSize = 8;

bool _isPowerOfTwo(int n) => n >= _minMipSize && (n & (n - 1)) == 0;

/// Lightweight, isolate-sendable handle referencing a wavetable loaded into an
/// [AudioHost] / [AudioEngine] via [AudioHostWavetableExtension.loadWavetable].
///
/// Wraps a [BufferHandle] with wavetable layout metadata so
/// [WavetableOscillator] can read frames and octave mipmaps safely.
class const WavetableHandle({
  /// Underlying buffer handle stored in [AudioEngine].
  required final BufferHandle buffer,

  /// Single-cycle length of level-0 frames in samples (power of two when
  /// [mipmapped] is `true`).
  required final int frameSize,

  /// Number of morphable waveform frames (`>= 1`).
  required final int numFrames,

  /// Whether each channel stores a halving band-limited mipmap chain of length
  /// `2 * frameSize` (`[frameSize | frameSize/2 | ... | 8]`).
  required final bool mipmapped,
}) {
  /// Wraps an arbitrary raw [BufferHandle] as an un-mipmapped wavetable
  /// (useful for live-recorded or external single/multi-cycle buffers).
  ///
  /// If [frameSize] is omitted, each channel of [buffer] is treated as one
  /// full cycle (`frameSize = buffer.length`, `numFrames = buffer.numChannels`).
  /// If [frameSize] is provided on a mono buffer, slices it into
  /// `buffer.length ~/ frameSize` concatenated frames (Serum/Vital style).
  factory fromBuffer(BufferHandle buffer, {int? frameSize}) {
    final int fs = frameSize ?? buffer.length;
    final int frames = buffer.numChannels > 1
        ? buffer.numChannels
        : (fs > 0 ? math.max(1, buffer.length ~/ fs) : 1);
    return WavetableHandle(
      buffer: buffer,
      frameSize: fs,
      numFrames: frames,
      mipmapped: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WavetableHandle &&
          buffer == other.buffer &&
          frameSize == other.frameSize &&
          numFrames == other.numFrames &&
          mipmapped == other.mipmapped;

  @override
  int get hashCode => Object.hash(buffer, frameSize, numFrames, mipmapped);

  @override
  String toString() =>
      'WavetableHandle(id: ${buffer.id}, $numFrames frames x $frameSize, '
      'mipmapped: $mipmapped)';
}

/// Host-side wavetable builder producing band-limited, multi-frame wavetables
/// backed by a standard planar [AudioBuffer].
///
/// Load into an [AudioHost] via `host.loadWavetable(table)` to obtain a
/// [WavetableHandle] for [WavetableOscillator].
class Wavetable._(
  final AudioBuffer _audioBuffer, {
  /// Level-0 single-cycle frame length in samples.
  required final int frameSize,

  /// Number of morphable frames (`>= 1`).
  required final int numFrames,

  /// Whether octave band-limited mipmaps are packed into each frame channel.
  required final bool mipmapped,
}) {
  /// Underlying planar [AudioBuffer] (`numChannels == numFrames`).
  AudioBuffer toAudioBuffer() => _audioBuffer;

  /// Classic 4-frame analog morph: **sine → triangle → sawtooth → square**.
  factory basicShapes({
    int frameSize = 2048,
    int maxHarmonics = 256,
  }) {
    _validateFrameSize(frameSize);
    final h = math.min(maxHarmonics, frameSize ~/ 4);
    final sine = List<double>.filled(h, 0.0)..[0] = 1.0;
    final tri = List<double>.generate(h, (i) {
      final k = i + 1;
      if (k.isEven) return 0.0;
      final sign = ((k - 1) ~/ 2).isEven ? 1.0 : -1.0;
      return sign / (k * k);
    });
    final saw = List<double>.generate(h, (i) => 1.0 / (i + 1));
    final square = List<double>.generate(
      h,
      (i) => (i + 1).isOdd ? 1.0 / (i + 1) : 0.0,
    );

    return Wavetable.fromHarmonics(
      [sine, tri, saw, square],
      frameSize: frameSize,
    );
  }

  /// 5-frame vocal formant morph: **A → E → I → O → U** (at ~130 Hz reference).
  factory formants({int frameSize = 2048}) {
    _validateFrameSize(frameSize);
    const double baseHz = 130.0;
    const int numHarmonics = 48;

    // Classic (F1, F2, F3) formant center frequencies in Hz for A, E, I, O, U.
    const vowels = [
      (730.0, 1090.0, 2440.0), // A ("ah")
      (530.0, 1840.0, 2480.0), // E ("eh")
      (270.0, 2290.0, 3010.0), // I ("ee")
      (570.0, 840.0, 2410.0), // O ("oh")
      (300.0, 870.0, 2240.0), // U ("oo")
    ];

    List<double> vowelHarmonics((double, double, double) f) {
      final (f1, f2, f3) = f;
      return List<double>.generate(numHarmonics, (i) {
        final freq = baseHz * (i + 1);
        final g1 = math.exp(-math.pow((freq - f1) / 140.0, 2));
        final g2 = 0.7 * math.exp(-math.pow((freq - f2) / 200.0, 2));
        final g3 = 0.35 * math.exp(-math.pow((freq - f3) / 260.0, 2));
        // Gentle glottal rolloff so higher harmonics don't sound brittle.
        final rolloff = 1.0 / math.pow(i + 1, 0.35);
        return (g1 + g2 + g3) * rolloff;
      });
    }

    return Wavetable.fromHarmonics(
      [for (final v in vowels) vowelHarmonics(v)],
      frameSize: frameSize,
    );
  }

  /// 4-frame Hammond-inspired drawbar organ morph (mellow flute → full jazz →
  /// gospel → bright percussive).
  factory Wavetable.organ({int frameSize = 2048}) {
    _validateFrameSize(frameSize);
    return Wavetable.fromHarmonics(const [
      [1.0, 0.4, 0.15, 0.0, 0.0, 0.0, 0.0, 0.0],
      [1.0, 0.8, 0.6, 0.4, 0.0, 0.25, 0.0, 0.15],
      [1.0, 1.0, 0.85, 0.7, 0.45, 0.6, 0.3, 0.5],
      [0.8, 1.0, 0.9, 1.0, 0.7, 0.9, 0.6, 1.0, 0.5, 0.7, 0.4, 0.5],
    ], frameSize: frameSize);
  }

  /// Builds a band-limited mipmapped wavetable from per-frame harmonic
  /// amplitude lists (index 0 = fundamental, index 1 = 2nd harmonic, etc.).
  factory fromHarmonics(
    List<List<double>> frames, {
    int frameSize = 2048,
    int sampleRate = 48000,
  }) {
    if (frames.isEmpty) {
      throw ArgumentError.value(frames, 'frames', 'must not be empty');
    }
    _validateFrameSize(frameSize);

    final rawFrames = <Float32List>[];
    for (final harmonics in frames) {
      final re = Float64List(frameSize);
      final im = Float64List(frameSize);
      final maxK = math.min(harmonics.length, frameSize ~/ 2 - 1);
      for (int k = 1; k <= maxK; k++) {
        final amp = harmonics[k - 1];
        if (amp == 0.0) continue;
        // Pure sine partial: Im[k] = -amp * N / 2, Im[N - k] = +amp * N / 2.
        final scaled = amp * (frameSize * 0.5);
        im[k] = -scaled;
        im[frameSize - k] = scaled;
      }
      _fft(re, im, inverse: true);
      final frame = Float32List(frameSize);
      double peak = 0.0;
      for (int i = 0; i < frameSize; i++) {
        final v = re[i];
        frame[i] = v;
        final a = v.abs();
        if (a > peak) peak = a;
      }
      if (peak > 1e-9) {
        final invPeak = 1.0 / peak;
        for (int i = 0; i < frameSize; i++) {
          frame[i] *= invPeak;
        }
      }
      rawFrames.add(frame);
    }

    return Wavetable.fromSamples(
      rawFrames,
      mipmap: true,
      sampleRate: sampleRate,
    );
  }

  /// Builds a wavetable from explicit single-cycle [frames].
  ///
  /// When [mipmap] is `true` (default), [frames] must have a power-of-two
  /// length `>= 8` and each frame is band-limited into a halving octave mipmap
  /// chain of length `2 * frameSize`.
  factory fromSamples(
    List<Float32List> frames, {
    bool mipmap = true,
    int sampleRate = 48000,
  }) {
    if (frames.isEmpty) {
      throw ArgumentError.value(frames, 'frames', 'must not be empty');
    }
    final frameSize = frames.first.length;
    if (frameSize <= 0) {
      throw ArgumentError.value(frameSize, 'frameSize', 'must be positive');
    }
    for (int i = 1; i < frames.length; i++) {
      if (frames[i].length != frameSize) {
        throw ArgumentError.value(
          frames,
          'frames',
          'All wavetable frames must have the same length.',
        );
      }
    }

    if (!mipmap) {
      return Wavetable._(
        AudioBuffer(
          channels: [for (final f in frames) Float32List.fromList(f)],
          sampleRate: sampleRate,
        ),
        frameSize: frameSize,
        numFrames: frames.length,
        mipmapped: false,
      );
    }

    _validateFrameSize(frameSize);
    final mipChannels = <Float32List>[
      for (final frame in frames) _buildMipChain(frame),
    ];

    return Wavetable._(
      AudioBuffer(channels: mipChannels, sampleRate: sampleRate),
      frameSize: frameSize,
      numFrames: frames.length,
      mipmapped: true,
    );
  }

  /// Slices an [AudioBuffer] (such as a concatenated mono Serum / Vital `.wav`
  /// wavetable) into [frameSize]-sample single-cycle frames and optionally
  /// generates band-limited octave mipmaps.
  factory fromBuffer(
    AudioBuffer buffer, {
    int frameSize = 2048,
    bool mipmap = true,
  }) {
    if (frameSize <= 0) {
      throw ArgumentError.value(frameSize, 'frameSize', 'must be positive');
    }
    final src = buffer[0];
    final count = src.length ~/ frameSize;
    if (count == 0) {
      throw ArgumentError.value(
        buffer.length,
        'buffer',
        'Buffer length (${buffer.length}) is shorter than frameSize ($frameSize).',
      );
    }
    final frames = List<Float32List>.generate(
      count,
      (i) => Float32List.sublistView(src, i * frameSize, (i + 1) * frameSize),
      growable: false,
    );
    return Wavetable.fromSamples(
      frames,
      mipmap: mipmap,
      sampleRate: buffer.sampleRate,
    );
  }

  static void _validateFrameSize(int frameSize) {
    if (!_isPowerOfTwo(frameSize)) {
      throw ArgumentError.value(
        frameSize,
        'frameSize',
        'Mipmapped wavetable frameSize must be a power of two >= $_minMipSize.',
      );
    }
  }
}

/// Extension on [AudioHost] for loading and unloading [Wavetable]s.
extension AudioHostWavetableExtension on AudioHost {
  /// Registers [table] in the underlying [AudioEngine] and returns a
  /// lightweight [WavetableHandle] for use with [WavetableOscillator].
  WavetableHandle loadWavetable(Wavetable table) {
    final bufferHandle = loadBuffer(table.toAudioBuffer());
    return WavetableHandle(
      buffer: bufferHandle,
      frameSize: table.frameSize,
      numFrames: table.numFrames,
      mipmapped: table.mipmapped,
    );
  }

  /// Unloads the underlying buffer for [handle] from the [AudioEngine].
  void unloadWavetable(WavetableHandle handle) => unloadBuffer(handle.buffer);
}

/// Builds a halving octave mipmap chain `[N | N/2 | N/4 | ... | 8]` of total
/// length `2 * N` from a power-of-two single-cycle [frame].
Float32List _buildMipChain(Float32List frame) {
  final int n = frame.length;
  final re = Float64List(n);
  final im = Float64List(n);
  for (int i = 0; i < n; i++) {
    re[i] = frame[i];
  }
  _fft(re, im, inverse: false);

  // Zero DC component so wavetable oscillators stay DC-centered.
  re[0] = 0.0;
  im[0] = 0.0;

  final chain = Float32List(n * 2);
  int offset = 0;
  int len = n;

  while (len >= _minMipSize) {
    final bool isTop = len == _minMipSize;
    final int maxHarmonic = isTop ? 1 : math.max(1, len ~/ 4);
    final levelRe = Float64List(len);
    final levelIm = Float64List(len);
    final double scale = len / n;

    final int limit = math.min(maxHarmonic, len ~/ 2 - 1);
    for (int k = 1; k <= limit; k++) {
      levelRe[k] = re[k] * scale;
      levelIm[k] = im[k] * scale;
      levelRe[len - k] = re[n - k] * scale;
      levelIm[len - k] = im[n - k] * scale;
    }

    _fft(levelRe, levelIm, inverse: true);
    for (int i = 0; i < len; i++) {
      chain[offset + i] = levelRe[i];
    }

    offset += len;
    len >>= 1;
  }

  return chain;
}

/// Minimal in-place Cooley-Tukey Radix-2 FFT (power-of-two lengths).
void _fft(Float64List re, Float64List im, {required bool inverse}) {
  final int n = re.length;
  // Bit-reversal permutation.
  int j = 0;
  for (int i = 1; i < n; i++) {
    int bit = n >> 1;
    while ((j & bit) != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
      final tmpRe = re[i];
      re[i] = re[j];
      re[j] = tmpRe;
      final tmpIm = im[i];
      im[i] = im[j];
      im[j] = tmpIm;
    }
  }

  final double dir = inverse ? 1.0 : -1.0;
  for (int size = 2; size <= n; size <<= 1) {
    final int half = size >> 1;
    final double angleStep = dir * 2.0 * math.pi / size;
    final double wStepRe = math.cos(angleStep);
    final double wStepIm = math.sin(angleStep);

    for (int start = 0; start < n; start += size) {
      double wRe = 1.0;
      double wIm = 0.0;
      for (int k = 0; k < half; k++) {
        final int even = start + k;
        final int odd = even + half;
        final double tRe = wRe * re[odd] - wIm * im[odd];
        final double tIm = wRe * im[odd] + wIm * re[odd];

        re[odd] = re[even] - tRe;
        im[odd] = im[even] - tIm;
        re[even] += tRe;
        im[even] += tIm;

        final nextWRe = wRe * wStepRe - wIm * wStepIm;
        wIm = wRe * wStepIm + wIm * wStepRe;
        wRe = nextWRe;
      }
    }
  }

  if (inverse) {
    final double invN = 1.0 / n;
    for (int i = 0; i < n; i++) {
      re[i] *= invN;
      im[i] *= invN;
    }
  }
}
