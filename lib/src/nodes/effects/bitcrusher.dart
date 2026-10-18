import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef BitcrusherParams = ({
  double? bitDepth,
  double? downsample,
  double? mix,
});

/// A digital degradation effect that performs bit-depth reduction (quantization)
/// and sample-rate reduction (sample-and-hold decimation).
///
/// Imparts vintage 8-bit/12-bit sampler crunch, chiptune textures, and metallic
/// aliasing sidebands.
///
/// See also:
/// - MusicDSP Decimator algorithm: https://www.musicdsp.org/en/latest/Effects/139-decimator.html
/// - Julius O. Smith (CCRMA, Stanford), "Quantization": https://ccrma.stanford.edu/~jos/pasp/Quantization.html
class Bitcrusher({
  required final List<Outlet> inputs,
  // TODO: consider int?
  /// Number of bits, 1-16. Use integer values.
  final ControlParam<double> bitDepth = const .value(8.0),

  /// Downsample factor. Values >= 1.0 disable downsampling.
  final ControlParam<double> downsample = const .value(1.0),

  /// Dry/Wet mix in [0.0, 1.0] (0.0 = 100% dry, 0.5 = 50/50, 1.0 = 100% wet).
  final ControlParam<double> mix = const .value(1.0),
}) implements AudioNode<BitcrusherProcessor> {
  factory mono({
    required Outlet input,
    ControlParam<double> bitDepth = const .value(8.0),
    ControlParam<double> downsample = const .value(1.0),
    ControlParam<double> mix = const .value(1.0),
  }) => Bitcrusher(
    inputs: [input],
    bitDepth: bitDepth,
    downsample: downsample,
    mix: mix,
  );

  factory stereo({
    required Outlet left,
    required Outlet right,
    ControlParam<double> bitDepth = const .value(8.0),
    ControlParam<double> downsample = const .value(1.0),
    ControlParam<double> mix = const .value(1.0),
  }) => Bitcrusher(
    inputs: [left, right],
    bitDepth: bitDepth,
    downsample: downsample,
    mix: mix,
  );

  static const bitDepthInlet = 0;
  static const downsampleInlet = 1;
  static const mixInlet = 2;
  static const audioInletOffset = 3;

  int get numChannels => inputs.length;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: bitDepthInlet, source: bitDepth.outletOrNull),
    Inlet(node: this, index: downsampleInlet, source: downsample.outletOrNull),
    Inlet(node: this, index: mixInlet, source: mix.outletOrNull),
    for (int i = 0; i < inputs.length; i++)
      Inlet(node: this, index: audioInletOffset + i, source: inputs[i]),
  ];

  @override
  List<Outlet> get outlets => List.generate(
    inputs.length,
    (i) => Outlet(node: this, index: i),
  );

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  bool canUpdate(covariant Bitcrusher other) =>
      runtimeType == other.runtimeType && numChannels == other.numChannels;

  @override
  BitcrusherProcessor createProcessor() => BitcrusherProcessor(
    numChannels: numChannels,
    bitDepth: bitDepth.valueOrNull,
    downsample: downsample.valueOrNull,
    mix: mix.valueOrNull,
  );

  @override
  BitcrusherParams get params => (
    bitDepth: bitDepth.valueOrNull,
    downsample: downsample.valueOrNull,
    mix: mix.valueOrNull,
  );
}

/// DSP processor implementing bit reduction (quantization) and sample-rate decimation.
///
/// Algorithmic references:
/// - MusicDSP Decimator / Sample-and-Hold: https://www.musicdsp.org/en/latest/Effects/139-decimator.html
/// - JOS (Stanford CCRMA), "Uniform Quantization": https://ccrma.stanford.edu/~jos/pasp/Quantization.html
class BitcrusherProcessor implements AudioProcessor {
  BitcrusherProcessor({
    required this.numChannels,
    this.bitDepth = 8.0,
    this.downsample = 1.0,
    this.mix = 1.0,
  }) : _heldSamples = Float32List(numChannels);

  final int numChannels;

  /// Target bit depth (1.0 to 16.0). Values >= 16.0 skip quantization.
  double? bitDepth;

  /// Downsample factor (>= 1.0). 1.0 = normal rate, 2.0 = half sample rate, etc.
  double? downsample;

  /// Dry/Wet mix in [0.0, 1.0] (0.0 = 100% dry, 0.5 = 50/50, 1.0 = 100% wet).
  double? mix;

  final Float32List _heldSamples;
  double _phase = 0.0;
  bool _initialized = false;

  // Cached quantization levels to avoid recomputing math.pow(2.0, ...) and divisions
  double _lastBits = -1.0;
  double _cachedLevels = 128.0;
  double _cachedInvLevels = 1.0 / 128.0;

  @override
  void update(Object params) {
    final p = params as BitcrusherParams;
    bitDepth = p.bitDepth;
    downsample = p.downsample;
    mix = p.mix;
  }

  @pragma('vm:prefer-inline')
  static double _quantizeSample(
    double sample,
    double levels,
    double invLevels,
  ) {
    return (sample.clamp(-1.0, 1.0) * levels).round() * invLevels;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final vectorSize = context.vectorSize;
    final int audioOffset = inputs.length > Bitcrusher.audioInletOffset
        ? Bitcrusher.audioInletOffset
        : 0;

    final staticBits = bitDepth;
    final staticDownsample = downsample;
    final staticMix = mix;

    final bitsBuffer =
        inputs.isNotEmpty && inputs.length > Bitcrusher.bitDepthInlet
        ? inputs[Bitcrusher.bitDepthInlet]
        : null;
    final downsampleBuffer = inputs.length > Bitcrusher.downsampleInlet
        ? inputs[Bitcrusher.downsampleInlet]
        : null;
    final mixBuffer = inputs.length > Bitcrusher.mixInlet
        ? inputs[Bitcrusher.mixInlet]
        : null;

    final bool hasSignalBits = staticBits == null && bitsBuffer != null;
    final bool hasSignalDownsample =
        staticDownsample == null && downsampleBuffer != null;
    final bool hasSignalMix = staticMix == null && mixBuffer != null;

    final double currentBits = staticBits ?? 8.0;
    final double currentDownsample = math.max(1.0, staticDownsample ?? 1.0);
    final double currentMix = staticMix ?? 1.0;

    // Fast-path: precalculate levels once per block if bit-depth is static
    if (!hasSignalBits && currentBits != _lastBits) {
      _lastBits = currentBits;
      if (currentBits < 16.0) {
        final intBits = currentBits.round().clamp(1, 16);
        _cachedLevels = (1 << (intBits - 1)).toDouble();
        _cachedInvLevels = 1.0 / _cachedLevels;
      }
    }

    double phase = _phase;
    bool initialized = _initialized;
    double levels = _cachedLevels;
    double invLevels = _cachedInvLevels;

    for (int i = 0; i < vectorSize; i++) {
      final double bits = hasSignalBits ? bitsBuffer[i] : currentBits;
      final double factor = hasSignalDownsample
          ? math.max(1.0, downsampleBuffer[i])
          : currentDownsample;
      final double mixVal = hasSignalMix ? mixBuffer[i] : currentMix;
      final (dryGain, wetGain) = linearMix(mixVal);

      if (!initialized || phase >= factor || factor <= 1.0) {
        initialized = true;
        if (phase >= factor && factor > 1.0) {
          phase -= factor;
        } else {
          phase = 0.0;
        }

        if (hasSignalBits && bits < 16.0) {
          final intBits = bits.round().clamp(1, 16);
          if (intBits.toDouble() != _lastBits) {
            _lastBits = intBits.toDouble();
            // pow(2, intBits - 1) but faster
            _cachedLevels = levels = (1 << (intBits - 1)).toDouble();
            _cachedInvLevels = invLevels = 1.0 / levels;
          }
        }

        for (int c = 0; c < numChannels; c++) {
          final inSample = inputs[c + audioOffset][i];
          _heldSamples[c] = bits >= 16.0
              ? inSample
              : _quantizeSample(inSample, levels, invLevels);
        }
      }

      for (int c = 0; c < numChannels; c++) {
        final dry = inputs[c + audioOffset][i];
        final wet = _heldSamples[c];
        outputs[c][i] = dry * dryGain + wet * wetGain;
      }

      phase += 1.0;
    }

    _phase = phase;
    _initialized = initialized;
  }
}
