import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef DelayParams = ({
  double? time,
  double? feedback,
  double? mix,
  double? damp,
  double maxDelay,
});

/// A multi-channel delay effect with feedback, 1-pole damping, and fractional
/// linear interpolation.
class Delay({
  required final List<Outlet> channels,
  final ControlParam<double> time = const .value(0.5),
  final ControlParam<double> feedback = const .value(0.0),
  final ControlParam<double> mix = const .value(0.5),
  final ControlParam<double> damp = const .value(0.0),
  final double maxDelay = 10.0,
}) extends AudioNode<DelayProcessor> {
  this : assert(maxDelay > 0.0, 'maxDelay must be positive');

  factory mono({
    required Outlet input,
    ControlParam<double> time = const .value(0.5),
    ControlParam<double> feedback = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    ControlParam<double> damp = const .value(0.0),
    double maxDelay = 10.0,
  }) => Delay(
    channels: [input],
    time: time,
    feedback: feedback,
    mix: mix,
    damp: damp,
    maxDelay: maxDelay,
  );

  factory stereo({
    required Outlet leftInput,
    required Outlet rightInput,
    ControlParam<double> time = const .value(0.5),
    ControlParam<double> feedback = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    ControlParam<double> damp = const .value(0.0),
    double maxDelay = 10.0,
  }) => Delay(
    channels: [leftInput, rightInput],
    time: time,
    feedback: feedback,
    mix: mix,
    damp: damp,
    maxDelay: maxDelay,
  );

  int get numChannels => channels.length;

  static const timeInlet = 0;
  static const feedbackInlet = 1;
  static const mixInlet = 2;
  static const dampInlet = 3;
  static const audioInletOffset = 4;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: timeInlet, source: time.outletOrNull),
    Inlet(node: this, index: feedbackInlet, source: feedback.outletOrNull),
    Inlet(node: this, index: mixInlet, source: mix.outletOrNull),
    Inlet(node: this, index: dampInlet, source: damp.outletOrNull),
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
  DelayProcessor createProcessor() => DelayProcessor(
    numChannels: numChannels,
    time: time.valueOrNull,
    feedback: feedback.valueOrNull,
    mix: mix.valueOrNull,
    damp: damp.valueOrNull,
    maxDelay: maxDelay,
  );

  @override
  DelayParams get params => (
    time: time.valueOrNull,
    feedback: feedback.valueOrNull,
    mix: mix.valueOrNull,
    damp: damp.valueOrNull,
    maxDelay: maxDelay,
  );

  @override
  List<AudioNodeError> get errors => [
    if (maxDelay <= 0)
      const AudioNodeParamError(param: 'maxDelay', error: 'must be positive'),
  ];

  // Ring buffer size is fixed.
  @override
  bool canUpdate(covariant Delay newNode) =>
      super.canUpdate(newNode) &&
      maxDelay == newNode.maxDelay &&
      numChannels == newNode.numChannels;
}

class DelayProcessor({
  required final int numChannels,
  var double? time,
  var double? feedback,
  var double? mix,
  var double? damp = 0.0,
  final double maxDelay = 10.0,
}) implements AudioProcessor {
  int _sampleRate = 0;
  int _bufferMask = 0;
  int _writeIndex = 0;
  List<Float32List>? _buffers;
  late final Float32List _dampStates = Float32List(numChannels);

  void _ensureBuffers(int sampleRate) {
    if (_sampleRate == sampleRate && _buffers != null) return;
    _sampleRate = sampleRate;

    // Allocate power-of-two ring buffer to cover maxDelay
    final needed = (maxDelay * sampleRate).ceil() + 4;
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
    final p = params as DelayParams;
    time = p.time;
    feedback = p.feedback;
    mix = p.mix;
    damp = p.damp;
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
    final maxDelaySamples = maxDelay * sampleRate;

    final time = this.time;
    final feedback = this.feedback;
    final mix = this.mix;
    final damp = this.damp;

    final int audioOffset = inputs.length > Delay.audioInletOffset
        ? Delay.audioInletOffset
        : 0;
    final Float32List? timeBuf = time == null && inputs.length > Delay.timeInlet
        ? inputs[Delay.timeInlet]
        : null;
    final Float32List? fbBuf =
        feedback == null && inputs.length > Delay.feedbackInlet
        ? inputs[Delay.feedbackInlet]
        : null;
    final Float32List? mixBuf = mix == null && inputs.length > Delay.mixInlet
        ? inputs[Delay.mixInlet]
        : null;
    final Float32List? dampBuf = damp == null && inputs.length > Delay.dampInlet
        ? inputs[Delay.dampInlet]
        : null;

    final double constFb = (feedback ?? 0.0).clamp(-0.999, 0.999);
    final double constDamp = (damp ?? 0.0).clamp(0.0, 1.0);
    final double constDelaySamples = time != null
        ? (time * sampleRate).clamp(1.0, maxDelaySamples)
        : 1.0;
    final (double constDry, double constWet) = mix != null
        ? equalPowerMix(mix)
        : (0.0, 0.0);

    int writeIndex = _writeIndex;

    for (int i = 0; i < length; i++) {
      // Resolve delay time in samples for this frame
      final double delaySamples;
      if (timeBuf != null) {
        delaySamples = (timeBuf[i] * sampleRate).clamp(1.0, maxDelaySamples);
      } else {
        delaySamples = constDelaySamples;
      }

      // Fractional sample decomposition
      // This is important if you don't want zzzzzip sounds
      final int intPart = delaySamples.floor();
      final double frac = delaySamples - intPart;

      final int read0 = (writeIndex - intPart) & mask;
      final int read1 = (read0 - 1) & mask;

      // Resolve feedback, damping, and dry/wet gains
      final double fb = fbBuf != null ? fbBuf[i].clamp(-0.999, 0.999) : constFb;
      final double dampCoef = dampBuf != null
          ? dampBuf[i].clamp(0.0, 1.0)
          : constDamp;
      final (double gainDry, double gainWet) = mixBuf != null
          ? equalPowerMix(mixBuf[i])
          : (constDry, constWet);

      for (int c = 0; c < numChannels; c++) {
        final buf = buffers[c];
        final inSample = inputs[audioOffset + c][i];

        // Linear interpolation across fractional delay
        final s0 = buf[read0];
        final s1 = buf[read1];
        final delayedSample = s0 + frac * (s1 - s0);

        // 1-pole lowpass filter in feedback path:
        // y[n] = delayedSample + d * (y[n-1] - delayedSample)
        final prevState = _dampStates[c];
        final damped = delayedSample + dampCoef * (prevState - delayedSample);
        _dampStates[c] = damped.abs() < 1e-15 ? 0.0 : damped;

        // Write input + damped feedback into ring buffer
        buf[writeIndex] = inSample + damped * fb;

        // Output equal-power dry/wet blend
        outputs[c][i] = inSample * gainDry + delayedSample * gainWet;
      }

      // Faster than modulo
      writeIndex = (writeIndex + 1) & mask;
    }

    _writeIndex = writeIndex;
  }
}
