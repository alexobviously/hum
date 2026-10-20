import 'dart:typed_data';

import 'package:hum/hum.dart';

// TODO: fully review AI code

typedef CombFilterParams = ({
  double? frequency,
  double? feedback,
  double? damp,
  double? mix,
  double minFrequency,
});

/// A tuned resonant feedback comb filter with sub-sample fractional linear
/// interpolation and 1-pole high-frequency damping.
///
/// Comb filters create a series of harmonically related resonant peaks spaced
/// at integer multiples of [frequency]:
/// `f0, 2*f0, 3*f0, ...`
///
/// - **Positive Feedback (`> 0.0`):** Produces all harmonic overtones,
///   modeling open acoustic cylinders (flutes) and vibrating strings.
/// - **Negative Feedback (`< 0.0`):** Produces odd harmonic overtones,
///   modeling closed cylinders (clarinets) and woody textures.
/// - **Damping (`damp`):** Emulates natural high-frequency energy loss in
///   acoustic media. `0.0` is bright and metallic; `0.5` to `0.8` produces warm
///   wooden or string pluck decays.
class CombFilter({
  required final List<Outlet> channels,
  final ControlParam<double> frequency = const .value(440.0),
  final ControlParam<double> feedback = const .value(0.9),
  final ControlParam<double> damp = const .value(0.0),
  final ControlParam<double> mix = const .value(0.5),
  final double minFrequency = 20.0,
}) implements AudioNode<CombFilterProcessor> {
  this : assert(minFrequency > 0.0, 'minFrequency must be positive');

  factory mono({
    required Outlet input,
    ControlParam<double> frequency = const .value(440.0),
    ControlParam<double> feedback = const .value(0.9),
    ControlParam<double> damp = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    double minFrequency = 20.0,
  }) => CombFilter(
    channels: [input],
    frequency: frequency,
    feedback: feedback,
    damp: damp,
    mix: mix,
    minFrequency: minFrequency,
  );

  factory stereo({
    required Outlet leftInput,
    required Outlet rightInput,
    ControlParam<double> frequency = const .value(440.0),
    ControlParam<double> feedback = const .value(0.9),
    ControlParam<double> damp = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    double minFrequency = 20.0,
  }) => CombFilter(
    channels: [leftInput, rightInput],
    frequency: frequency,
    feedback: feedback,
    damp: damp,
    mix: mix,
    minFrequency: minFrequency,
  );

  int get numChannels => channels.length;

  static const frequencyInlet = 0;
  static const feedbackInlet = 1;
  static const dampInlet = 2;
  static const mixInlet = 3;
  static const audioInletOffset = 4;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: frequencyInlet, source: frequency.outletOrNull),
    Inlet(node: this, index: feedbackInlet, source: feedback.outletOrNull),
    Inlet(node: this, index: dampInlet, source: damp.outletOrNull),
    Inlet(node: this, index: mixInlet, source: mix.outletOrNull),
    ...List.generate(
      numChannels,
      (i) =>
          Inlet(node: this, index: audioInletOffset + i, source: channels[i]),
    ),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(numChannels, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  CombFilterProcessor createProcessor() => CombFilterProcessor(
    numChannels: numChannels,
    frequency: frequency.valueOrNull,
    feedback: feedback.valueOrNull,
    damp: damp.valueOrNull,
    mix: mix.valueOrNull,
    minFrequency: minFrequency,
  );

  @override
  CombFilterParams get params => (
    frequency: frequency.valueOrNull,
    feedback: feedback.valueOrNull,
    damp: damp.valueOrNull,
    mix: mix.valueOrNull,
    minFrequency: minFrequency,
  );
}

class CombFilterProcessor({
  required final int numChannels,
  var double? frequency,
  var double? feedback,
  var double? damp,
  var double? mix,
  final double minFrequency = 20.0,
}) implements AudioProcessor {
  int _sampleRate = 0;
  int _bufferMask = 0;
  int _writeIndex = 0;
  List<Float32List>? _buffers;
  late final Float32List _dampStates = Float32List(numChannels);

  void _ensureBuffers(int sampleRate) {
    if (_sampleRate == sampleRate && _buffers != null) return;
    _sampleRate = sampleRate;

    // Minimum delay buffer size covers down to minFrequency with headroom
    final needed = (sampleRate / minFrequency).ceil() + 4;
    int size = 1;
    while (size < needed) {
      size <<= 1;
    }
    _bufferMask = size - 1;
    _writeIndex = 0;
    _buffers = List.generate(numChannels, (_) => Float32List(size));
  }

  @override
  void update(Object params) {
    final p = params as CombFilterParams;
    frequency = p.frequency;
    feedback = p.feedback;
    damp = p.damp;
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

    // Guard rails for pitch/frequency bounds
    final maxFreq = sampleRate * 0.49;
    final maxDelaySamples = (sampleRate / minFrequency).clamp(
      2.0,
      mask.toDouble(),
    );

    final frequency = this.frequency;
    final feedback = this.feedback;
    final damp = this.damp;
    final mix = this.mix;

    final int audioOffset = inputs.length > CombFilter.audioInletOffset
        ? CombFilter.audioInletOffset
        : 0;

    final Float32List? freqBuf =
        frequency == null && inputs.length > CombFilter.frequencyInlet
        ? inputs[CombFilter.frequencyInlet]
        : null;
    final Float32List? fbBuf =
        feedback == null && inputs.length > CombFilter.feedbackInlet
        ? inputs[CombFilter.feedbackInlet]
        : null;
    final Float32List? dampBuf =
        damp == null && inputs.length > CombFilter.dampInlet
        ? inputs[CombFilter.dampInlet]
        : null;
    final Float32List? mixBuf =
        mix == null && inputs.length > CombFilter.mixInlet
        ? inputs[CombFilter.mixInlet]
        : null;

    final double constFreq = (frequency ?? 440.0).clamp(minFrequency, maxFreq);
    final double constFb = (feedback ?? 0.9).clamp(-0.9999, 0.9999);
    final double constDamp = (damp ?? 0.0).clamp(0.0, 1.0);
    final (double constDry, double constWet) = mix != null
        ? equalPowerMix(mix)
        : (0.0, 1.0);

    int writeIndex = _writeIndex;

    for (int i = 0; i < length; i++) {
      // Resolve frequency and delay length in samples
      final double freq = freqBuf != null
          ? freqBuf[i].clamp(minFrequency, maxFreq)
          : constFreq;
      final double delaySamples = (sampleRate / freq).clamp(
        2.0,
        maxDelaySamples,
      );

      // Fractional sample decomposition
      final int intPart = delaySamples.floor();
      final double frac = delaySamples - intPart;

      final int read0 = (writeIndex - intPart) & mask;
      final int read1 = (read0 - 1) & mask;

      final double fb = fbBuf != null
          ? fbBuf[i].clamp(-0.9999, 0.9999)
          : constFb;
      final double dampCoef = dampBuf != null
          ? dampBuf[i].clamp(0.0, 1.0)
          : constDamp;
      final (double gainDry, double gainWet) = mixBuf != null
          ? equalPowerMix(mixBuf[i])
          : (constDry, constWet);

      for (int c = 0; c < numChannels; c++) {
        final buf = buffers[c];
        final inSample = inputs[audioOffset + c][i];

        // Linear interpolation across fractional delay pointer
        final s0 = buf[read0];
        final s1 = buf[read1];
        final delayedSample = s0 + frac * (s1 - s0);

        // 1-pole lowpass filter in feedback path
        final prevState = _dampStates[c];
        final damped = delayedSample + dampCoef * (prevState - delayedSample);
        _dampStates[c] = damped.abs() < 1e-15 ? 0.0 : damped;

        // Recirculate damped feedback into the delay ring buffer
        buf[writeIndex] = inSample + damped * fb;

        // Output equal-power blend of dry input and resonated wet signal
        outputs[c][i] = inSample * gainDry + delayedSample * gainWet;
      }

      writeIndex = (writeIndex + 1) & mask;
    }

    _writeIndex = writeIndex;
  }
}

extension CombFilterOutletExtension on Outlet {
  /// Routes this outlet through a tuned resonant [CombFilter].
  CombFilter comb({
    ControlParam<double> frequency = const .value(440.0),
    ControlParam<double> feedback = const .value(0.9),
    ControlParam<double> damp = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    double minFrequency = 20.0,
  }) => CombFilter.mono(
    input: this,
    frequency: frequency,
    feedback: feedback,
    damp: damp,
    mix: mix,
    minFrequency: minFrequency,
  );
}
