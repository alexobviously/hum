import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Parameter bag for updating a [BranchProcessor] in-place.
typedef BranchParams = ({List<double>? weights, int? maxConsecutive});

/// An N-way weighted probabilistic trigger and gate router.
///
/// Generalizes [Chance] to an arbitrary number of output branches: on each
/// rising edge (`<= 0` -> `> 0`) of [input], rolls a weighted random choice
/// across [weights] (auto-normalized), latches the chosen outlet for the full
/// duration of the gate, and passes the exact input sample value through.
///
/// Set [maxConsecutive] to cap streaks on the same outlet (`1` prevents any
/// consecutive repeat; `2` allows at most two hits in a row; `null` is
/// unlimited).
class Branch({
  /// Input trigger or gate signal to route.
  required final Outlet input,

  /// Non-negative relative weights for each output branch (auto-normalized;
  /// at least one weight must be positive).
  required final List<double> weights,

  /// Optional maximum number of consecutive hits allowed on the same outlet
  /// (`1` = never twice in a row, `2` = up to two in a row, `null` = unlimited).
  /// Ignored if fewer than two outlets have positive weight.
  final int? maxConsecutive,

  /// Optional RNG seed for deterministic routing.
  final int? seed,
}) extends AudioNode<BranchProcessor> {
  /// Equal-probability routing across [count] outlets.
  factory uniform({
    required Outlet input,
    required int count,
    int? maxConsecutive,
    int? seed,
  }) => Branch(
    input: input,
    weights: List<double>.filled(count, 1.0, growable: false),
    maxConsecutive: maxConsecutive,
    seed: seed,
  );

  static const inputInlet = 0;

  /// Number of output branches.
  int get count => weights.length;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: inputInlet, source: input),
  ];

  @override
  late final List<Outlet> outlets = [
    for (int i = 0; i < weights.length; i++) Outlet(node: this, index: i),
  ];

  /// Convenience indexer into [outlets].
  Outlet operator [](int index) => outlets[index];

  @override
  BranchProcessor createProcessor() => BranchProcessor(
    weights: weights,
    maxConsecutive: maxConsecutive,
    seed: seed,
  );

  @override
  List<AudioNodeError> get errors {
    final errs = <AudioNodeError>[];
    if (weights.isEmpty) {
      errs.add(
        const AudioNodeParamError(param: 'weights', error: 'must not be empty'),
      );
    } else {
      bool hasPositive = false;
      for (final w in weights) {
        if (!w.isFinite || w < 0.0) {
          errs.add(
            const AudioNodeParamError(
              param: 'weights',
              error: 'all weights must be finite and non-negative',
            ),
          );
          break;
        }
        if (w > 0.0) hasPositive = true;
      }
      if (!hasPositive) {
        errs.add(
          const AudioNodeParamError(
            param: 'weights',
            error: 'at least one weight must be positive',
          ),
        );
      }
    }
    if (maxConsecutive != null && maxConsecutive! <= 0) {
      errs.add(
        const AudioNodeParamError(
          param: 'maxConsecutive',
          error: 'must be positive when provided',
        ),
      );
    }
    return errs;
  }

  @override
  List<Object?> get fixedProps => [weights.length, seed];

  @override
  List<Object?> get dynamicProps => [weights, maxConsecutive];

  @override
  Object get params => (
    weights: List<double>.unmodifiable(weights),
    maxConsecutive: maxConsecutive,
  );
}

/// Runtime processor for [Branch].
class BranchProcessor({
  required List<double> weights,
  int? maxConsecutive,
  int? seed,
}) implements AudioProcessor {
  final int _numOutputs = weights.length;
  final Float64List _weights = Float64List.fromList(weights);
  final math.Random _rng = math.Random(seed);

  double _totalWeight = 0.0;
  int _positiveCount = 0;
  int? _maxConsecutive = maxConsecutive;

  bool _wasHigh = false;
  int _activeIndex = 0;
  int _lastIndex = -1;
  int _streak = 0;

  this {
    _recomputeTotals();
  }

  void _recomputeTotals() {
    double total = 0.0;
    int pos = 0;
    for (int i = 0; i < _numOutputs; i++) {
      final w = _weights[i];
      if (w > 0.0) {
        total += w;
        pos++;
      }
    }
    _totalWeight = total;
    _positiveCount = pos;
  }

  @override
  void update(Object params) {
    if (params case final BranchParams p) {
      if (p.weights case final nextWeights?
          when nextWeights.length == _numOutputs) {
        for (int i = 0; i < _numOutputs; i++) {
          _weights[i] = nextWeights[i] > 0.0 ? nextWeights[i] : 0.0;
        }
        _recomputeTotals();
      }
      if (p.maxConsecutive != null) {
        _maxConsecutive = p.maxConsecutive;
      }
    }
  }

  int _pickBranch() {
    final bool excludeLast =
        _maxConsecutive != null &&
        _positiveCount >= 2 &&
        _lastIndex >= 0 &&
        _streak >= _maxConsecutive!;

    final double effectiveTotal = excludeLast
        ? _totalWeight - _weights[_lastIndex]
        : _totalWeight;

    if (effectiveTotal <= 0.0) return 0;

    double roll = _rng.nextDouble() * effectiveTotal;
    int chosen = _numOutputs - 1;
    for (int i = 0; i < _numOutputs; i++) {
      if (excludeLast && i == _lastIndex) continue;
      final w = _weights[i];
      if (w <= 0.0) continue;
      if (roll < w) {
        chosen = i;
        break;
      }
      roll -= w;
      chosen = i;
    }

    if (chosen == _lastIndex) {
      _streak++;
    } else {
      _lastIndex = chosen;
      _streak = 1;
    }
    return chosen;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final input = inputs[Branch.inputInlet];
    final int n = context.vectorSize;

    for (int i = 0; i < n; i++) {
      final double v = input[i];
      final bool isHigh = v > 0.0;

      if (isHigh && !_wasHigh) {
        _activeIndex = _pickBranch();
      }
      _wasHigh = isHigh;

      for (int ch = 0; ch < _numOutputs; ch++) {
        outputs[ch][i] = (isHigh && ch == _activeIndex) ? v : 0.0;
      }
    }
  }
}
