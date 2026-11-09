import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef DelayParams = ({
  double? time,
  double? feedback,
  double? mix,
  double? damp,
  double maxDelay,
  double interpTime,
});

/// A multi-channel delay effect with feedback, 1-pole damping, fractional
/// linear interpolation, and clickless parameter slewing.
class Delay({
  required final List<Outlet> channels,
  final ControlParam<double> time = const .value(0.5),
  final ControlParam<double> feedback = const .value(0.0),
  final ControlParam<double> mix = const .value(0.5),
  final ControlParam<double> damp = const .value(0.0),
  final double maxDelay = 10.0,
  final double interpTime = 0.06,
}) extends AudioNode<DelayProcessor> {
  this : assert(maxDelay > 0.0, 'maxDelay must be positive');

  factory mono({
    required Outlet input,
    ControlParam<double> time = const .value(0.5),
    ControlParam<double> feedback = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    ControlParam<double> damp = const .value(0.0),
    double maxDelay = 10.0,
    double interpTime = 0.06,
  }) => Delay(
    channels: [input],
    time: time,
    feedback: feedback,
    mix: mix,
    damp: damp,
    maxDelay: maxDelay,
    interpTime: interpTime,
  );

  factory stereo({
    required Outlet leftInput,
    required Outlet rightInput,
    ControlParam<double> time = const .value(0.5),
    ControlParam<double> feedback = const .value(0.0),
    ControlParam<double> mix = const .value(0.5),
    ControlParam<double> damp = const .value(0.0),
    double maxDelay = 10.0,
    double interpTime = 0.06,
  }) => Delay(
    channels: [leftInput, rightInput],
    time: time,
    feedback: feedback,
    mix: mix,
    damp: damp,
    maxDelay: maxDelay,
    interpTime: interpTime,
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
    interpTime: interpTime,
  );

  @override
  DelayParams get params => (
    time: time.valueOrNull,
    feedback: feedback.valueOrNull,
    mix: mix.valueOrNull,
    damp: damp.valueOrNull,
    maxDelay: maxDelay,
    interpTime: interpTime,
  );

  @override
  List<AudioNodeError> get errors => [
    if (maxDelay <= 0)
      const AudioNodeParamError(param: 'maxDelay', error: 'must be positive'),
    if (interpTime < 0)
      const AudioNodeParamError(
        param: 'interpTime',
        error: 'must be non-negative',
      ),
  ];

  @override
  List<Object?> get fixedProps => [maxDelay];

  @override
  List<Object?> get dynamicProps => [time, feedback, mix, damp, interpTime];
}

class DelayProcessor({
  required final int numChannels,
  var double? time,
  var double? feedback,
  var double? mix,
  var double? damp = 0.0,
  final double maxDelay = 10.0,
  var double interpTime = 0.06,
}) implements AudioProcessor {
  int _sampleRate = 0;
  int _bufferMask = 0;
  int _writeIndex = 0;
  List<Float32List>? _buffers;
  late final Float32List _dampStates = Float32List(numChannels);

  // This is to prevent artefacts when parameters change.
  late final SmoothedValue _fbSmoother = SmoothedValue(feedback ?? 0.0);
  late final SmoothedValue _mixSmoother = SmoothedValue(mix ?? 0.5);
  late final SmoothedValue _dampSmoother = SmoothedValue(damp ?? 0.0);

  double _currentDelaySamples = 1.0;
  double _targetDelaySamples = 1.0;

  // TODO: consider crossfade mode (alternative to smoothing)

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
    _currentDelaySamples = ((time ?? 0.0) * sampleRate).fastClamp(
      1.0,
      maxDelay * sampleRate,
    );
    _targetDelaySamples = _currentDelaySamples;
  }

  @override
  void update(Object params) {
    final p = params as DelayParams;
    final oldTime = time;
    final oldFb = feedback;
    final oldMix = mix;
    final oldDamp = damp;
    time = p.time;
    feedback = p.feedback;
    mix = p.mix;
    damp = p.damp;
    interpTime = p.interpTime;

    if (p.time != null) {
      if (_sampleRate > 0) {
        _targetDelaySamples = (p.time! * _sampleRate).fastClamp(
          1.0,
          maxDelay * _sampleRate,
        );
      }
      if (oldTime == null || interpTime <= 0.0) {
        _currentDelaySamples = _targetDelaySamples;
      }
    }

    if (p.feedback != null) {
      if (oldFb == null || interpTime <= 0.0) {
        _fbSmoother.snapTo(p.feedback!);
      } else {
        _fbSmoother.setTarget(p.feedback!);
      }
    }

    if (p.mix != null) {
      if (oldMix == null || interpTime <= 0.0) {
        _mixSmoother.snapTo(p.mix!);
      } else {
        _mixSmoother.setTarget(p.mix!);
      }
    }

    if (p.damp != null) {
      if (oldDamp == null || interpTime <= 0.0) {
        _dampSmoother.snapTo(p.damp!);
      } else {
        _dampSmoother.setTarget(p.damp!);
      }
    }
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

    _fbSmoother.configure(sampleRate: sampleRate, rampTime: interpTime);
    _mixSmoother.configure(sampleRate: sampleRate, rampTime: interpTime);
    _dampSmoother.configure(sampleRate: sampleRate, rampTime: interpTime);

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

    final bool isTimeSettled = _currentDelaySamples == _targetDelaySamples;
    final bool isFbSettled = _fbSmoother.isSettled;
    final bool isMixSettled = _mixSmoother.isSettled;
    final bool isDampSettled = _dampSmoother.isSettled;

    final double constDelaySamples = _targetDelaySamples;
    final double constFb = (feedback != null && isFbSettled)
        ? _fbSmoother.current.fastClamp(-0.999, 0.999)
        : (feedback ?? 0.0).fastClamp(-0.999, 0.999);
    final double constDamp = (damp != null && isDampSettled)
        ? _dampSmoother.current.fastClamp(0.0, 1.0)
        : (damp ?? 0.0).fastClamp(0.0, 1.0);
    final double constDry = (mix != null && isMixSettled)
        ? equalPowerDry(_mixSmoother.current)
        : 0.0;
    final double constWet = (mix != null && isMixSettled)
        ? equalPowerWet(_mixSmoother.current)
        : 0.0;

    final double timeCoeff = (interpTime <= 0.0 || sampleRate <= 0.0)
        ? 1.0
        : (1.0 - math.exp(-6.907755278982137 / (sampleRate * interpTime)));
    // Max tape slew rate: 0.75 samples/frame bounds read speed between 0.25x and 1.75x,
    // guaranteeing no buffer skips or direction reversals (eliminating zipper noise).
    final double maxTapeSlew = interpTime <= 0.0 ? double.infinity : 0.75;

    int writeIndex = _writeIndex;

    for (int i = 0; i < length; i++) {
      // Resolve delay time in samples for this frame
      final double delaySamples;
      if (timeBuf != null) {
        delaySamples = (timeBuf[i] * sampleRate).fastClamp(
          1.0,
          maxDelaySamples,
        );
      } else if (time != null) {
        if (!isTimeSettled) {
          final diff = _targetDelaySamples - _currentDelaySamples;
          if (diff.abs() < 1e-4) {
            _currentDelaySamples = _targetDelaySamples;
          } else {
            final step = (diff * timeCoeff).fastClamp(
              -maxTapeSlew,
              maxTapeSlew,
            );
            _currentDelaySamples += step;
          }
          delaySamples = _currentDelaySamples;
        } else {
          delaySamples = constDelaySamples;
        }
      } else {
        delaySamples = 1.0;
      }

      // Fractional sample decomposition
      // This is important if you don't want zzzzzip sounds
      final int intPart = delaySamples.floor();
      final double frac = delaySamples - intPart;

      final int read0 = (writeIndex - intPart) & mask;
      final int read1 = (read0 - 1) & mask;

      // Resolve feedback, damping, and dry/wet gains
      final double fb = fbBuf != null
          ? fbBuf[i].fastClamp(-0.999, 0.999)
          : (feedback != null
                ? (!isFbSettled
                      ? _fbSmoother.next().fastClamp(-0.999, 0.999)
                      : constFb)
                : constFb);
      final double dampCoef = dampBuf != null
          ? dampBuf[i].fastClamp(0.0, 1.0)
          : (damp != null
                ? (!isDampSettled
                      ? _dampSmoother.next().fastClamp(0.0, 1.0)
                      : constDamp)
                : constDamp);
      final double gainDry;
      final double gainWet;
      if (mixBuf != null) {
        final m = mixBuf[i];
        gainDry = equalPowerDry(m);
        gainWet = equalPowerWet(m);
      } else if (mix != null) {
        if (!isMixSettled) {
          final m = _mixSmoother.next();
          gainDry = equalPowerDry(m);
          gainWet = equalPowerWet(m);
        } else {
          gainDry = constDry;
          gainWet = constWet;
        }
      } else {
        gainDry = 0.0;
        gainWet = 0.0;
      }

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
