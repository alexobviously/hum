import 'dart:math';
import 'dart:typed_data';

import 'package:dsp/dsp.dart';

enum OnePoleType { lowpass, highpass }

typedef OnePoleParams = ({double? cutoff, OnePoleType type});

class OnePoleFilter implements AudioNode<OnePoleProcessor> {
  final ControlParam<double> cutoff;
  final OnePoleType type;
  final Outlet input;

  const OnePoleFilter({
    required this.cutoff,
    required this.input,
    this.type = .lowpass,
  });

  static const inputInlet = 0;
  static const cutoffInlet = 1;
  static const outputOutlet = 0;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: inputInlet, source: input),
    Inlet(node: this, index: cutoffInlet, source: cutoff.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: outputOutlet)];

  Outlet get outlet => outlets.first;

  @override
  OnePoleProcessor createProcessor() =>
      OnePoleProcessor(cutoff: cutoff.valueOrNull, type: type);

  @override
  OnePoleParams get params => (cutoff: cutoff.valueOrNull, type: type);
}

class OnePoleProcessor implements AudioProcessor {
  double? cutoff;
  OnePoleType type;

  OnePoleProcessor({this.cutoff, required this.type});

  double _lastSample = 0;

  @override
  void update(Object params) {
    params = params as OnePoleParams;
    cutoff = params.cutoff;
    type = params.type;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final input = inputs[OnePoleFilter.inputInlet];
    final output = outputs[OnePoleFilter.outputOutlet];
    final length = output.length;
    final sampleRate = context.sampleRate;
    final cutoff = this.cutoff;
    final type = this.type;

    if (cutoff == null) {
      final cutoffBuffer = inputs[OnePoleFilter.cutoffInlet];

      for (int i = 0; i < length; i++) {
        final coef = _coefficient(cutoffBuffer[i], sampleRate);

        _lastSample = coef * _lastSample + (1 - coef) * input[i];
        output[i] = switch (type) {
          .lowpass => _lastSample,
          .highpass => input[i] - _lastSample,
        };
      }
    } else {
      final coef = _coefficient(cutoff, sampleRate);

      for (int i = 0; i < length; i++) {
        _lastSample = coef * _lastSample + (1 - coef) * input[i];
        output[i] = switch (type) {
          .lowpass => _lastSample,
          .highpass => input[i] - _lastSample,
        };
      }
    }
  }
}

double _coefficient(double cutoff, int sampleRate) =>
    exp(-(2 * pi * cutoff) / sampleRate);

// It would be possible to swap out exp() for Taylor's approximation:
// 1.0 - x + 0.5 * x * x
// But it's ok really in 2026, exp() is fast.
