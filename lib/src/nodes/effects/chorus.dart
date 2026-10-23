import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

// TODO: fully review AI code

typedef ChorusParams = ({
  double? rate,
  double? depth,
  double? baseDelay,
  double? feedback,
  double? mix,
  double stereoPhase,
  double maxDelay,
});

/// A multi-channel stereo chorus and ensemble effect.
///
/// Chorus simulates multiple independent instruments playing in unison by
/// routing audio through short delay lines modulated by low-frequency
/// oscillators (LFOs). The subtle Doppler pitch shifts and timing variations
/// create shimmering acoustic width and natural beating.
///
/// - **`rate`**: Modulation frequency in Hz (typically 0.2 to 5.0 Hz).
/// - **`depth`**: Modulation excursion in seconds (typically 0.001 to 0.005 s / 1 to 5 ms).
/// - **`baseDelay`**: Center delay in seconds (typically 0.010 to 0.025 s / 10 to 25 ms).
/// - **`feedback`**: Amount of delayed signal fed back into the delay line.
///   `0.0` produces clean chorus; higher values create flanging and resonant color.
/// - **`mix`**: Equal-power dry/wet balance. `0.5` provides classic chorus beating;
///   `1.0` produces pure vibrato / pitch modulation.
/// - **`stereoPhase`**: Phase offset between channels in radians. Defaults to
///   90 degrees (pi / 2) for lush quadrature stereo spread.
class Chorus({
  required final List<Outlet> channels,
  final int? outputsCount,
  final ControlParam<double> rate = const .value(1.2),
  final ControlParam<double> depth = const .value(0.003),
  final ControlParam<double> baseDelay = const .value(0.015),
  final ControlParam<double> feedback = const .value(0.0),
  final ControlParam<double> mix = const .value(0.5),
  final double stereoPhase = math.pi * 0.5,
  final double maxDelay = 0.05,
}) implements AudioNode<ChorusProcessor> {
  this : assert(maxDelay > 0.0, 'maxDelay must be positive');

  int get numOutputs => outputsCount ?? channels.length;

  factory mono({
    required Outlet input,
    ControlParam<double> rate = const .value(1.2),
    ControlParam<double> depth = const .value(0.003),
    ControlParam<double> baseDelay = const .value(0.015),
    ControlParam<double> feedback = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    double maxDelay = 0.05,
  }) => Chorus(
    channels: [input],
    outputsCount: 1,
    rate: rate,
    depth: depth,
    baseDelay: baseDelay,
    feedback: feedback,
    mix: mix,
    maxDelay: maxDelay,
  );

  factory stereo({
    required Outlet leftInput,
    required Outlet rightInput,
    ControlParam<double> rate = const .value(1.2),
    ControlParam<double> depth = const .value(0.003),
    ControlParam<double> baseDelay = const .value(0.015),
    ControlParam<double> feedback = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    double stereoPhase = math.pi * 0.5,
    double maxDelay = 0.05,
  }) => Chorus(
    channels: [leftInput, rightInput],
    outputsCount: 2,
    rate: rate,
    depth: depth,
    baseDelay: baseDelay,
    feedback: feedback,
    mix: mix,
    stereoPhase: stereoPhase,
    maxDelay: maxDelay,
  );

  /// Spreads a single mono [input] across two stereo outputs with
  /// phase-offset LFO modulation.
  factory toStereo({
    required Outlet input,
    ControlParam<double> rate = const .value(1.2),
    ControlParam<double> depth = const .value(0.003),
    ControlParam<double> baseDelay = const .value(0.015),
    ControlParam<double> feedback = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    double stereoPhase = math.pi * 0.5,
    double maxDelay = 0.05,
  }) => Chorus(
    channels: [input],
    outputsCount: 2,
    rate: rate,
    depth: depth,
    baseDelay: baseDelay,
    feedback: feedback,
    mix: mix,
    stereoPhase: stereoPhase,
    maxDelay: maxDelay,
  );

  int get numChannels => channels.length;

  static const rateInlet = 0;
  static const depthInlet = 1;
  static const baseDelayInlet = 2;
  static const feedbackInlet = 3;
  static const mixInlet = 4;
  static const audioInletOffset = 5;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: rateInlet, source: rate.outletOrNull),
    Inlet(node: this, index: depthInlet, source: depth.outletOrNull),
    Inlet(node: this, index: baseDelayInlet, source: baseDelay.outletOrNull),
    Inlet(node: this, index: feedbackInlet, source: feedback.outletOrNull),
    Inlet(node: this, index: mixInlet, source: mix.outletOrNull),
    ...List.generate(
      channels.length,
      (i) =>
          Inlet(node: this, index: audioInletOffset + i, source: channels[i]),
    ),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(numOutputs, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  ChorusProcessor createProcessor() => ChorusProcessor(
    numInputs: channels.length,
    numOutputs: numOutputs,
    rate: rate.valueOrNull,
    depth: depth.valueOrNull,
    baseDelay: baseDelay.valueOrNull,
    feedback: feedback.valueOrNull,
    mix: mix.valueOrNull,
    stereoPhase: stereoPhase,
    maxDelay: maxDelay,
  );

  @override
  ChorusParams get params => (
    rate: rate.valueOrNull,
    depth: depth.valueOrNull,
    baseDelay: baseDelay.valueOrNull,
    feedback: feedback.valueOrNull,
    mix: mix.valueOrNull,
    stereoPhase: stereoPhase,
    maxDelay: maxDelay,
  );
}

class ChorusProcessor({
  required final int numInputs,
  required final int numOutputs,
  var double? rate,
  var double? depth,
  var double? baseDelay,
  var double? feedback,
  var double? mix,
  final double stereoPhase = math.pi * 0.5,
  final double maxDelay = 0.05,
}) implements AudioProcessor {
  int _sampleRate = 0;
  int _bufferMask = 0;
  int _writeIndex = 0;
  double _lfoPhase = 0.0;
  List<Float32List>? _buffers;

  void _ensureBuffers(int sampleRate) {
    if (_sampleRate == sampleRate && _buffers != null) return;
    _sampleRate = sampleRate;

    final needed = (maxDelay * sampleRate).ceil() + 4;
    int size = 1;
    while (size < needed) {
      size <<= 1;
    }
    _bufferMask = size - 1;
    _writeIndex = 0;
    _buffers = List.generate(numOutputs, (_) => Float32List(size));
  }

  @override
  void update(Object params) {
    final p = params as ChorusParams;
    rate = p.rate;
    depth = p.depth;
    baseDelay = p.baseDelay;
    feedback = p.feedback;
    mix = p.mix;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    _ensureBuffers(context.sampleRate);

    final buffers = _buffers!;
    final mask = _bufferMask;
    final length = context.vectorSize;
    final sampleRate = context.sampleRate.toDouble();
    final maxDelaySamples = (maxDelay * sampleRate).clamp(1.0, mask.toDouble());

    final rate = this.rate;
    final depth = this.depth;
    final baseDelay = this.baseDelay;
    final feedback = this.feedback;
    final mix = this.mix;

    final int audioOffset = inputs.length > Chorus.audioInletOffset
        ? Chorus.audioInletOffset
        : 0;

    final Float32List? rateBuf =
        rate == null && inputs.length > Chorus.rateInlet
        ? inputs[Chorus.rateInlet]
        : null;
    final Float32List? depthBuf =
        depth == null && inputs.length > Chorus.depthInlet
        ? inputs[Chorus.depthInlet]
        : null;
    final Float32List? baseDelayBuf =
        baseDelay == null && inputs.length > Chorus.baseDelayInlet
        ? inputs[Chorus.baseDelayInlet]
        : null;
    final Float32List? fbBuf =
        feedback == null && inputs.length > Chorus.feedbackInlet
        ? inputs[Chorus.feedbackInlet]
        : null;
    final Float32List? mixBuf = mix == null && inputs.length > Chorus.mixInlet
        ? inputs[Chorus.mixInlet]
        : null;

    final double constRate = (rate ?? 1.2).clamp(0.01, 20.0);
    final double constDepth = (depth ?? 0.003).clamp(0.0, maxDelay * 0.5);
    final double constBaseDelay = (baseDelay ?? 0.015).clamp(
      0.0005,
      maxDelay - constDepth,
    );
    final double constFb = (feedback ?? 0.0).clamp(-0.95, 0.95);
    final (double constDry, double constWet) = mix != null
        ? equalPowerMix(mix)
        : (0.7071, 0.7071);

    int writeIndex = _writeIndex;
    double lfoPhase = _lfoPhase;
    final double phaseOffsetPerChannel = stereoPhase / (2.0 * math.pi);

    for (int i = 0; i < length; i++) {
      final double curRate = rateBuf != null
          ? rateBuf[i].clamp(0.01, 20.0)
          : constRate;
      final double curDepth = depthBuf != null
          ? depthBuf[i].clamp(0.0, maxDelay * 0.5)
          : constDepth;
      final double curBaseDelay = baseDelayBuf != null
          ? baseDelayBuf[i].clamp(0.0005, maxDelay - curDepth)
          : constBaseDelay;
      final double fb = fbBuf != null ? fbBuf[i].clamp(-0.95, 0.95) : constFb;
      final (double gainDry, double gainWet) = mixBuf != null
          ? equalPowerMix(mixBuf[i])
          : (constDry, constWet);

      for (int c = 0; c < numOutputs; c++) {
        // Map input channel (supports mono-to-stereo broadcast)
        final int inChannelIndex = audioOffset + (c < numInputs ? c : 0);
        final double inSample = inputs[inChannelIndex][i];

        // Multi-channel LFO phase
        final double chPhase = (lfoPhase + c * phaseOffsetPerChannel) % 1.0;
        final double lfoVal = math.sin(chPhase * 2.0 * math.pi);

        // Modulated delay time in samples
        final double delayTime = curBaseDelay + curDepth * lfoVal;
        final double delaySamples = (delayTime * sampleRate).clamp(
          1.0,
          maxDelaySamples,
        );

        // Sub-sample linear interpolation
        final int intPart = delaySamples.floor();
        final double frac = delaySamples - intPart;

        final int read0 = (writeIndex - intPart) & mask;
        final int read1 = (read0 - 1) & mask;

        final buf = buffers[c];
        final double s0 = buf[read0];
        final double s1 = buf[read1];
        final double delayedSample = s0 + frac * (s1 - s0);

        // Write input + feedback into delay buffer
        buf[writeIndex] = inSample + delayedSample * fb;

        // Output dry/wet mix
        outputs[c][i] = inSample * gainDry + delayedSample * gainWet;
      }

      writeIndex = (writeIndex + 1) & mask;
      lfoPhase = (lfoPhase + (curRate / sampleRate)) % 1.0;
    }

    _writeIndex = writeIndex;
    _lfoPhase = lfoPhase;
  }
}

extension ChorusOutletExtension on Outlet {
  /// Routes this outlet through a [Chorus] effect.
  Chorus chorus({
    ControlParam<double> rate = const .value(1.2),
    ControlParam<double> depth = const .value(0.003),
    ControlParam<double> baseDelay = const .value(0.015),
    ControlParam<double> feedback = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    double stereoPhase = math.pi * 0.5,
    bool toStereo = false,
  }) => toStereo
      ? .toStereo(
          input: this,
          rate: rate,
          depth: depth,
          baseDelay: baseDelay,
          feedback: feedback,
          mix: mix,
          stereoPhase: stereoPhase,
        )
      : .mono(
          input: this,
          rate: rate,
          depth: depth,
          baseDelay: baseDelay,
          feedback: feedback,
          mix: mix,
        );
}
