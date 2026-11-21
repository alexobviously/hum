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
}) extends AudioNode<StepSequencerProcessor> with TelemetryNode<int> {
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

  /// Convenience factory taking an iterable of musical note names (e.g.
  /// `['C4', 'E4', 'G4', 'B4']`) and converting them to frequencies in Hertz.
  factory notes({
    required Outlet clock,
    Outlet? reset,
    required Iterable<String> notes,
    double a4 = 440.0,
    double threshold = 0.5,
  }) => StepSequencer.fromList(
    clock: clock,
    reset: reset,
    steps: notes.toHz(a4),
    threshold: threshold,
  );

  /// Convenience factory parsing a whitespace-separated sequence of note names
  /// (e.g. `'C4 E4 G4 B4'`) into frequencies in Hertz.
  factory sequence({
    required Outlet clock,
    Outlet? reset,
    required String sequence,
    double a4 = 440.0,
    double threshold = 0.5,
  }) => StepSequencer.fromList(
    clock: clock,
    reset: reset,
    steps: sequence.toHz(a4),
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

  @override
  List<AudioNodeError> get errors => [
    if (steps.valueOrNull?.isEmpty ?? true)
      const AudioNodeParamError(param: 'steps', error: 'must not be empty'),
  ];

  @override
  List<Object?> get fixedProps => [reset != null];

  @override
  List<Object?> get dynamicProps => [steps, threshold];

  @override
  int decodeTelemetry(Float32List data) => data[0].toInt();
}

class StepSequencerProcessor({
  required List<double> steps,
  var double threshold = 0.5,
  var bool hasReset = false,
}) implements TelemetryProcessor {
  Float32List _steps = Float32List.fromList(steps);

  int _currentStep = 0;
  bool _isFirstPulse = true;
  bool _wasClockHigh = false;
  bool _wasResetHigh = false;
  bool _telemetryDirty = false;

  @override
  int get telemetryLength => 1;

  @override
  bool writeTelemetry(Float32List out, int offset) {
    if (!_telemetryDirty) return false;
    _telemetryDirty = false;
    out[offset] = _currentStep.toDouble();
    return true;
  }

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
    bool telemetryDirty = _telemetryDirty;

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
          telemetryDirty = true;
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
        telemetryDirty = true;
      }
      wasClockHigh = isClockHigh;

      out[i] = steps[currentStep];
    }

    _currentStep = currentStep;
    _isFirstPulse = isFirstPulse;
    _wasClockHigh = wasClockHigh;
    _wasResetHigh = wasResetHigh;
    _telemetryDirty = telemetryDirty;
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
