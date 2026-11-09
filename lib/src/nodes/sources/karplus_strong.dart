import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef KarplusStrongParams = ({double? frequency, double? feedback});

/// Naive physical model of a string.
class KarplusStrong({
  required final Outlet gate,
  required final ControlParam<double> frequency,
  required final ControlParam<double> feedback,
}) extends AudioNode<KarplusStrongProcessor> {
  static const gateInlet = 0;
  static const frequencyInlet = 1;
  static const feedbackInlet = 2;
  static const outputOutlet = 0;

  @override
  KarplusStrongProcessor createProcessor() => KarplusStrongProcessor(
    frequency: frequency.valueOrNull,
    feedback: feedback.valueOrNull,
  );

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: gateInlet, source: gate),
    Inlet(node: this, index: frequencyInlet, source: frequency.outletOrNull),
    Inlet(node: this, index: feedbackInlet, source: feedback.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: outputOutlet)];

  Outlet get outlet => outlets.first;

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [frequency, feedback];

  @override
  KarplusStrongParams get params =>
      (frequency: frequency.valueOrNull, feedback: feedback.valueOrNull);
}

class KarplusStrongProcessor({
  required var double? frequency,
  required var double? feedback,
}) implements AudioProcessor {
  @override
  void update(Object params) {
    params = params as KarplusStrongParams;
    frequency = params.frequency;
    feedback = params.feedback;
  }

  // Long enough to cover down to like 10Hz.
  final Float32List _buffer = Float32List(4096);
  static const int _bufferMask = 4095;
  int _bufferWriteIndex = 0;

  double _lastFilterSample = 0.0;

  bool _lastGate = false;
  int _burstRemaining = 0;

  int _rngState = 123456789;
  // TODO: consider drying, if performant?
  /// Xorshift. See [NoiseGenerator]. ~10x faster than Random().
  double _nextNoise() {
    int x = _rngState;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= (x >> 17);
    x ^= (x << 5) & 0xFFFFFFFF;
    _rngState = x;
    return (x & 0x00FFFFFF) * (2.0 / 0x00FFFFFF) - 1.0;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final sampleRate = context.sampleRate;
    final output = outputs[KarplusStrong.outputOutlet];
    final gateBuffer = inputs[KarplusStrong.gateInlet];

    final Float32List? freqBuf = frequency == null
        ? inputs[KarplusStrong.frequencyInlet]
        : null;
    final Float32List? fbBuf = feedback == null
        ? inputs[KarplusStrong.feedbackInlet]
        : null;

    final double constFreq = frequency ?? 0.0;
    final double constFeedback = feedback ?? 0.0;

    int writeIndex = _bufferWriteIndex;
    final double maxFreq = sampleRate * 0.45;

    for (int i = 0; i < output.length; i++) {
      final bool isGateHigh = gateBuffer[i] > 0.0;
      final double rawFreq = freqBuf == null ? constFreq : freqBuf[i];
      final double freq = rawFreq.clamp(20.0, maxFreq);
      final double rawFb = fbBuf == null ? constFeedback : fbBuf[i];
      final double fb = rawFb.clamp(0.0, 0.9999);

      if (isGateHigh && !_lastGate) {
        // Impulse length is equal to delay period.
        _burstRemaining = (sampleRate / freq).round();
      }
      _lastGate = isGateHigh;

      double excitation = 0;
      if (_burstRemaining > 0) {
        excitation = _nextNoise();
        _burstRemaining--;
      }

      // -0.5 to adjust for the inherent delay in the filter.
      final double delaySamples = (sampleRate / freq) - 0.5;

      final int intPart = delaySamples.floor();
      final double frac = delaySamples - intPart;
      final int read0 = (writeIndex - intPart) & _bufferMask;
      final int read1 = (read0 - 1) & _bufferMask;
      final double delayedSample =
          _buffer[read0] + frac * (_buffer[read1] - _buffer[read0]);

      // TODO: parameterise this for brightness or whatever
      // Super simple two point filter.
      final double lowpassed = 0.5 * (delayedSample + _lastFilterSample);
      _lastFilterSample = delayedSample;

      final double sample = excitation + lowpassed * fb;
      _buffer[writeIndex] = sample;
      output[i] = sample;
      writeIndex = (writeIndex + 1) & _bufferMask;
    }

    _bufferWriteIndex = writeIndex;
  }
}
