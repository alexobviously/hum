import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef StepSequencerParams = ({
  List<double> steps,
  double threshold,
  bool hasReset,
});

/// A synchronous step sequencer that steps through a series of values (e.g. pitch
/// or control voltages) on each rising edge of a [clock] trigger.
///
/// Outputs a single held value stream via [outlet] / [cv].
class StepSequencer({
  required final Outlet clock,
  final Outlet? reset,
  required final ControlParam<List<double>> steps,
  final double threshold = 0.5,
}) implements AudioNode<StepSequencerProcessor> {
  /// Convenience factory taking a plain [List<double>].
  factory fromList({
    required Outlet clock,
    Outlet? reset,
    required List<double> steps,
    double threshold = 0.5,
  }) => StepSequencer(
    clock: clock,
    reset: reset,
    steps: .value(steps),
    threshold: threshold,
  );

  static const clockInlet = 0;
  static const resetInlet = 1;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: clockInlet, source: clock),
    Inlet(node: this, index: resetInlet, source: reset),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: 0),
  ];

  /// The held value of the current sequence step.
  Outlet get outlet => outlets.first;

  /// Alias for [outlet].
  Outlet get cv => outlets.first;

  @override
  StepSequencerProcessor createProcessor() => StepSequencerProcessor(
    steps: steps.valueOrNull ?? const [],
    threshold: threshold,
    hasReset: reset != null,
  );

  @override
  StepSequencerParams get params => (
    steps: steps.valueOrNull ?? const [],
    threshold: threshold,
    hasReset: reset != null,
  );
}

class StepSequencerProcessor({
  required List<double> steps,
  var double threshold = 0.5,
  var bool hasReset = false,
}) implements AudioProcessor {
  Float32List _steps = Float32List.fromList(steps);

  int _currentStep = 0;
  bool _isFirstPulse = true;
  bool _wasClockHigh = false;
  bool _wasResetHigh = false;

  @override
  void update(Object params) {
    final p = params as StepSequencerParams;
    threshold = p.threshold;
    hasReset = p.hasReset;
    _steps = Float32List.fromList(p.steps);
    if (_steps.isNotEmpty && _currentStep >= _steps.length) {
      _currentStep %= _steps.length;
    }
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final clockBuf = inputs[StepSequencer.clockInlet];
    final resetBuf = inputs[StepSequencer.resetInlet];
    final out = outputs[0];

    final steps = _steps;
    final int numSteps = steps.length;
    final double thresh = threshold;
    final bool checkReset = hasReset;

    int currentStep = _currentStep;
    bool isFirstPulse = _isFirstPulse;
    bool wasClockHigh = _wasClockHigh;
    bool wasResetHigh = _wasResetHigh;

    if (numSteps == 0) {
      out.fillRange(0, out.length, 0.0);
      return;
    }

    for (int i = 0; i < out.length; i++) {
      if (checkReset) {
        final bool isResetHigh = resetBuf[i] >= thresh;
        if (isResetHigh && !wasResetHigh) {
          currentStep = 0;
          isFirstPulse = true;
        }
        wasResetHigh = isResetHigh;
      }

      final bool isClockHigh = clockBuf[i] >= thresh;
      if (isClockHigh && !wasClockHigh) {
        if (isFirstPulse) {
          isFirstPulse = false;
          currentStep = 0;
        } else {
          currentStep = (currentStep + 1) % numSteps;
        }
      }
      wasClockHigh = isClockHigh;

      out[i] = steps[currentStep];
    }

    _currentStep = currentStep;
    _isFirstPulse = isFirstPulse;
    _wasClockHigh = wasClockHigh;
    _wasResetHigh = wasResetHigh;
  }
}

extension StepSequencerExtension on Outlet {
  /// Steps through [steps] on each rising edge of this outlet.
  StepSequencer stepSequencer({
    required List<double> steps,
    Outlet? reset,
    double threshold = 0.5,
  }) => StepSequencer.fromList(
    clock: this,
    reset: reset,
    steps: steps,
    threshold: threshold,
  );
}
