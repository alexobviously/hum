import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Playback traversal order for [StepSequencer].
enum StepMode {
  /// Steps forward `0, 1, ..., N-1, 0, ...`.
  forward,

  /// Steps backward `N-1, N-2, ..., 0, N-1, ...`.
  reverse,

  /// Bounces back and forth `0, 1, ..., N-1, N-2, ..., 1, 0, ...`.
  pingPong,

  /// Picks a uniformly random step on every clock pulse.
  random,

  /// Picks a uniformly random step on every clock pulse without repeating the
  /// immediately preceding step (when `steps.length >= 2`).
  randomNoRepeat,
}

typedef StepSequencerParams = ({
  List<double> steps,
  double threshold,
  bool hasReset,
  StepMode mode,
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
  final StepMode mode = .forward,
  final int? seed,
}) extends AudioNode<StepSequencerProcessor> with TelemetryNode<int> {
  /// Convenience factory taking a plain [List<double>].
  factory fromList({
    required Outlet clock,
    Outlet? reset,
    required List<double> steps,
    double threshold = 0.5,
    StepMode mode = .forward,
    int? seed,
  }) => StepSequencer(
    clock: clock,
    reset: reset,
    steps: .value(steps),
    threshold: threshold,
    mode: mode,
    seed: seed,
  );

  /// Convenience factory taking an iterable of musical note names (e.g.
  /// `['C4', 'E4', 'G4', 'B4']`) and converting them to frequencies in Hertz.
  factory notes({
    required Outlet clock,
    Outlet? reset,
    required Iterable<String> notes,
    double a4 = 440.0,
    double threshold = 0.5,
    StepMode mode = .forward,
    int? seed,
  }) => StepSequencer.fromList(
    clock: clock,
    reset: reset,
    steps: notes.toHz(a4),
    threshold: threshold,
    mode: mode,
    seed: seed,
  );

  /// Convenience factory parsing a whitespace-separated sequence of note names
  /// (e.g. `'C4 E4 G4 B4'`) into frequencies in Hertz.
  factory sequence({
    required Outlet clock,
    Outlet? reset,
    required String sequence,
    double a4 = 440.0,
    double threshold = 0.5,
    StepMode mode = .forward,
    int? seed,
  }) => StepSequencer.fromList(
    clock: clock,
    reset: reset,
    steps: sequence.toHz(a4),
    threshold: threshold,
    mode: mode,
    seed: seed,
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
    mode: mode,
    seed: seed,
  );

  @override
  StepSequencerParams get params => (
    steps: steps.valueOrNull ?? const [],
    threshold: threshold,
    hasReset: reset != null,
    mode: mode,
  );

  @override
  List<AudioNodeError> get errors => [
    if (steps.valueOrNull?.isEmpty ?? true)
      const AudioNodeParamError(param: 'steps', error: 'must not be empty'),
  ];

  @override
  List<Object?> get fixedProps => [reset != null, seed];

  @override
  List<Object?> get dynamicProps => [steps, threshold, mode];

  @override
  int decodeTelemetry(Float32List data) => data[0].toInt();
}

class StepSequencerProcessor({
  required List<double> steps,
  var double threshold = 0.5,
  var bool hasReset = false,
  var StepMode mode = .forward,
  int? seed,
}) implements TelemetryProcessor {
  Float32List _steps = Float32List.fromList(steps);
  final math.Random _rng = math.Random(seed);

  int _currentStep = 0;
  int _pingPongDir = 1;
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
    mode = p.mode;
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
    final StepMode stepMode = mode;

    int currentStep = _currentStep;
    int pingPongDir = _pingPongDir;
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
          currentStep = stepMode == .reverse ? numSteps - 1 : 0;
          pingPongDir = 1;
          isFirstPulse = true;
          telemetryDirty = true;
        }
        wasResetHigh = isResetHigh;
      }

      final bool isClockHigh = clockBuf[i] >= thresh;
      if (isClockHigh && !wasClockHigh) {
        if (isFirstPulse) {
          isFirstPulse = false;
          currentStep = switch (stepMode) {
            .forward || .pingPong => 0,
            .reverse => numSteps - 1,
            .random || .randomNoRepeat => _rng.nextInt(numSteps),
          };
          pingPongDir = 1;
        } else {
          switch (stepMode) {
            case .forward:
              currentStep = (currentStep + 1) % numSteps;
            case .reverse:
              currentStep = (currentStep - 1 + numSteps) % numSteps;
            case .pingPong:
              if (numSteps > 1) {
                int next = currentStep + pingPongDir;
                if (next >= numSteps) {
                  pingPongDir = -1;
                  next = numSteps - 2;
                } else if (next < 0) {
                  pingPongDir = 1;
                  next = 1;
                }
                currentStep = next;
              }
            case .random:
              currentStep = _rng.nextInt(numSteps);
            case .randomNoRepeat:
              if (numSteps > 1) {
                final r = _rng.nextInt(numSteps - 1);
                currentStep = r >= currentStep ? r + 1 : r;
              }
          }
        }
        telemetryDirty = true;
      }
      wasClockHigh = isClockHigh;

      out[i] = steps[currentStep];
    }

    _currentStep = currentStep;
    _pingPongDir = pingPongDir;
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
    StepMode mode = .forward,
    int? seed,
  }) => StepSequencer.fromList(
    clock: this,
    reset: reset,
    steps: steps,
    threshold: threshold,
    mode: mode,
    seed: seed,
  );
}
