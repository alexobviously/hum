import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Reusable mixin providing in-place single-pole DC blocking (5-10 Hz highpass)
/// for any [AudioProcessor].
///
/// Implements the canonical digital DC blocker difference equation:
/// ```text
/// y[n] = x[n] - x[n-1] + R * y[n-1]
/// ```
/// where `R = 1.0 - (2 * pi * cutoffHz / sampleRate)`.
///
/// Features:
/// - **Zero Allocation**: Operates directly in-place on target output buffers.
/// - **Arbitrary Channel Count**: Dynamically sizes per-channel filter state
///   (`x[n-1]`, `y[n-1]`) to match any channel count.
/// - **Sample-Rate Adaptive**: Dynamically recalculates pole `R` when the
///   processing context sample rate changes.
mixin DcBlockMixin {
  // These are tiny lists, the length of these is just the number of channels.
  // They're lists precisely so this mixin can support multiple channels.
  Float64List? _dcX1;
  Float64List? _dcY1;

  double _cachedSampleRate = 0.0;
  double _cachedCutoff = 5.0;
  double _dcR = 0.9993;

  /// Ensures internal channel states match [numChannels] and computes pole `R`.
  void ensureDcBlockState(
    int numChannels, {
    required double sampleRate,
    double cutoffHz = 5.0,
  }) {
    if (_dcX1 == null || _dcX1!.length != numChannels) {
      _dcX1 = Float64List(numChannels);
      _dcY1 = Float64List(numChannels);
    }

    if (_cachedSampleRate != sampleRate || _cachedCutoff != cutoffHz) {
      _cachedSampleRate = sampleRate;
      _cachedCutoff = cutoffHz;
      // Pole placement for highpass corner at cutoffHz:
      // R = 1.0 - (2 * pi * cutoffHz / sampleRate)
      _dcR = 1.0 - (2.0 * math.pi * cutoffHz / sampleRate);
      if (_dcR < 0.9) _dcR = 0.9;
      if (_dcR > 0.9999) _dcR = 0.9999;
    }
  }

  /// Applies DC blocking in-place to [buffer] for the specified [channel].
  @pragma('vm:prefer-inline')
  void applyDcBlock(
    Float32List buffer,
    int channel,
    int length, {
    required double sampleRate,
    double cutoffHz = 5.0,
  }) {
    final x1List = _dcX1;
    final y1List = _dcY1;
    if (x1List == null ||
        y1List == null ||
        channel >= x1List.length ||
        _cachedSampleRate != sampleRate) {
      ensureDcBlockState(
        math.max(channel + 1, x1List?.length ?? 1),
        sampleRate: sampleRate,
        cutoffHz: cutoffHz,
      );
    }

    final localX1List = _dcX1!;
    final localY1List = _dcY1!;
    double x1 = localX1List[channel];
    double y1 = localY1List[channel];
    final r = _dcR;

    for (int i = 0; i < length; i++) {
      final x = buffer[i];
      final y = x - x1 + r * y1;
      x1 = x;
      y1 = y;
      buffer[i] = y;
    }

    localX1List[channel] = x1;
    localY1List[channel] = y1;
  }

  /// Resets internal DC blocker history (clears DC memory).
  void resetDcBlock() {
    _dcX1?.fillRange(0, _dcX1!.length, 0.0);
    _dcY1?.fillRange(0, _dcY1!.length, 0.0);
  }
}

typedef DCBlockParams = ({double? cutoffHz});

/// An [AudioNode] that removes 0 Hz DC offset and sub-audible infrasound drift
/// from incoming audio [channels].
///
/// Uses an efficient 1-pole recursive difference equation (`y[n] = x[n] - x[n-1] + R * y[n-1]`)
/// tuned to an ultra-low cutoff (default: 5.0 Hz).
///
/// Crucial for:
/// - Re-centering waveforms after asymmetric waveshaping or half-wave rectification.
/// - Cleaning microphone inputs before dynamic compression or speech recognition.
/// - Placing at master bus outputs before speakers to protect voice coils and maximize headroom.
class const DCBlock({
  required final List<Outlet> channels,
  final double cutoffHz = 5.0,
}) extends AudioNode<DCBlockProcessor> {
  factory mono(Outlet input, {double cutoffHz = 5.0}) =>
      DCBlock(channels: [input], cutoffHz: cutoffHz);

  factory stereo(
    Outlet leftInput,
    Outlet rightInput, {
    double cutoffHz = 5.0,
  }) => DCBlock(channels: [leftInput, rightInput], cutoffHz: cutoffHz);

  int get numChannels => channels.length;

  @override
  List<Inlet> get inlets => List.generate(
    channels.length,
    (i) => Inlet(node: this, index: i, source: channels[i]),
  );

  @override
  List<Outlet> get outlets =>
      List.generate(channels.length, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [cutoffHz];

  @override
  DCBlockProcessor createProcessor() =>
      DCBlockProcessor(numChannels: numChannels, cutoffHz: cutoffHz);

  @override
  DCBlockParams get params => (cutoffHz: cutoffHz);
}

/// Processor implementing single-pole DC blocking via [DcBlockMixin].
class DCBlockProcessor({
  required final int numChannels,
  var double cutoffHz = 5.0,
}) with DcBlockMixin implements AudioProcessor {
  @override
  void update(Object params) {
    final p = params as DCBlockParams;
    cutoffHz = p.cutoffHz ?? cutoffHz;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final sr = context.sampleRate.toDouble();

    ensureDcBlockState(numChannels, sampleRate: sr, cutoffHz: cutoffHz);

    for (int c = 0; c < numChannels; c++) {
      final inBuf = inputs[c];
      final outBuf = outputs[c];

      // Copy input to output, then apply DC block in-place
      outBuf.setRange(0, length, inBuf);
      applyDcBlock(outBuf, c, length, sampleRate: sr, cutoffHz: cutoffHz);
    }
  }
}

extension OutletDcBlockExtension on Outlet {
  /// Applies a 5 Hz single-pole DC blocker to strip DC offset from this outlet.
  DCBlock dcBlock({double cutoffHz = 5.0}) =>
      DCBlock.mono(this, cutoffHz: cutoffHz);
}
