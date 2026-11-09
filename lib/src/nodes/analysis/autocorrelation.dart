import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

// TODO: revisit this. I temporarily abandoned it to do something else.

/// An audio node that performs time-domain autocorrelation to detect pitch.
///
/// Features a zero-cost audio passthrough outlet, while exposing the detected
/// fundamental period [bestLag] and [frequency] on its processor.
class Autocorrelation extends AudioNode<AutocorrelationProcessor> {
  final Outlet input;
  final int windowSize;
  final int hopSize;
  final double minFrequency;
  final double maxFrequency;

  Autocorrelation({
    required this.input,
    this.windowSize = 1024,
    this.hopSize = 512,
    this.minFrequency = 50.0,
    this.maxFrequency = 1000.0,
  });

  @override
  List<Inlet> get inlets => [Inlet(node: this, index: 0, source: input)];

  @override
  late final List<Outlet> outlets = [Outlet(node: this, index: 0)];

  /// Audio passthrough outlet.
  Outlet get outlet => outlets[0];

  @override
  AutocorrelationProcessor createProcessor() => AutocorrelationProcessor(
    windowSize: windowSize,
    hopSize: hopSize,
    minFrequency: minFrequency,
    maxFrequency: maxFrequency,
  );

  @override
  Object get params => ();
}

/// The runtime processor for [Autocorrelation].
class AutocorrelationProcessor implements AudioProcessor {
  AutocorrelationProcessor({
    this.windowSize = 1024,
    this.hopSize = 512,
    this.minFrequency = 50.0,
    this.maxFrequency = 1000.0,
  }) {
    // Sized to hold window + maximum lag tau for up to 48 kHz
    final int maxTau = (48000 / minFrequency).ceil();
    _ring = Float32List(windowSize + maxTau);
    _linear = Float32List(windowSize + maxTau);
  }

  final int windowSize;
  final int hopSize;
  final double minFrequency;
  final double maxFrequency;

  late final Float32List _ring;
  late final Float32List _linear;

  int _writeIdx = 0;
  int _hopCount = 0;

  /// The detected pitch period in samples (tau).
  int bestLag = 0;

  /// The detected fundamental frequency in Hz (0.0 if not yet detected).
  double frequency = 0.0;

  /// The maximum autocorrelation peak value.
  double maxCorrelation = 0.0;

  @override
  void update(Object params) {}

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final input = inputs[0];
    final vectorSize = context.vectorSize;

    // Passthrough audio
    if (outputs.isNotEmpty) {
      outputs[0].setRange(0, vectorSize, input);
    }

    // Push incoming samples into ring buffer
    final ringLen = _ring.length;
    for (int i = 0; i < vectorSize; i++) {
      _ring[_writeIdx] = input[i];
      _writeIdx = (_writeIdx + 1) % ringLen;
    }

    // Trigger correlation on hop boundaries
    _hopCount += vectorSize;
    if (_hopCount >= hopSize) {
      _hopCount = 0;
      _correlate(context.sampleRate);
    }
  }

  void _correlate(int sampleRate) {
    final int maxTau = (sampleRate / minFrequency).ceil().clamp(
      1,
      _ring.length - windowSize,
    );
    final int minTau = math.max(1, (sampleRate / maxFrequency).floor());
    final int totalNeeded = windowSize + maxTau;
    final int ringLen = _ring.length;

    // Unroll ring buffer into contiguous linear buffer
    for (int i = 0; i < totalNeeded; i++) {
      _linear[i] = _ring[(_writeIdx - totalNeeded + i + ringLen * 4) % ringLen];
    }

    final int numLags = maxTau - minTau + 1;
    final corr = Float32List(numLags);
    double highestPeak = 0.0;

    // 1. Calculate autocorrelation across all lags
    for (int tau = minTau; tau <= maxTau; tau++) {
      double sum = 0.0;
      for (int j = 0; j < windowSize; j++) {
        sum += _linear[j] * _linear[j + tau];
      }
      final int lagIdx = tau - minTau;
      corr[lagIdx] = sum;
      if (sum > highestPeak) {
        highestPeak = sum;
      }
    }

    // 2. Find the FIRST local peak close to the maximum (>= 85%).
    // This identifies the fundamental period instead of multiples (2*tau, 3*tau).
    int peakLag = 0;
    final double threshold = highestPeak * 0.85;

    for (int i = 1; i < numLags - 1; i++) {
      if (corr[i] > corr[i - 1] &&
          corr[i] >= corr[i + 1] &&
          corr[i] >= threshold) {
        peakLag = minTau + i;
        break;
      }
    }

    // Fall back to highest peak if no distinct local peak found
    if (peakLag == 0) {
      for (int i = 0; i < numLags; i++) {
        if (corr[i] == highestPeak) {
          peakLag = minTau + i;
          break;
        }
      }
    }

    bestLag = peakLag;
    maxCorrelation = highestPeak;
    frequency = peakLag > 0 ? sampleRate / peakLag : 0.0;
  }
}
