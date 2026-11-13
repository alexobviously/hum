import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

// TODO: humanise this comment a bit

typedef ChanceParams = ({double? probability});

/// Type aliases for [Chance].
typedef BernoulliGate = Chance;

/// A probabilistic trigger and gate router (Bernoulli Gate).
///
/// Routes incoming events to either [a] (pass) or [b] (alternate) based on
/// a configurable [probability] threshold (ranging from 0.0 to 1.0).
///
/// ### Supported Input Signals:
/// * **Single-Sample Triggers:** Discrete impulses (such as `clock.trigger` or
///   `stepSequencer.trigger`). A 1-sample pulse will be routed exclusively out of
///   either outlet [a] or [b].
/// * **Sustained Gate Pulses:** Variable-length held signals (such as `clock.gate`
///   or keyboard note-on gates). On the rising edge of the gate, [Chance] rolls
///   a single random coin flip and latches the routing decision. The selected
///   outlet remains high for the **entire duration** of the gate, and turns off
///   when the input falls low, preventing mid-gate chattering or stuttering.
/// * **Dynamic Values & Accents:** [Chance] passes through the exact incoming
///   sample value (e.g. velocity amplitudes or accent levels) rather than forcing
///   a hardcoded 1.0.
///
/// ### Common Applications:
/// * **Groove Humanization & Ghost Notes:** Setting [probability] to 0.85 to route
///   most hi-hat hits to a closed hat and 15% to ghost notes or open hats.
/// * **Generative Melodic Duets:** Splitting an arpeggio sequence between two distinct
///   synthesizer voices.
/// * **Probabilistic Note Mutes:** Leaving outlet [b] disconnected so that notes are
///   dropped at a given chance rate.
///
/// Named after the Bernoulli distribution in probability theory, and popularized in
/// modular synthesis by the Mutable Instruments Branches module.
class Chance({
  required final Outlet input,
  final ControlParam<double> probability = const .value(0.5),
  final int? seed,
}) extends AudioNode<ChanceProcessor> {
  static const inputInlet = 0;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: inputInlet, source: input),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: 0),
    Outlet(node: this, index: 1),
  ];

  /// Primary output (routed when random roll is strictly less than [probability]).
  Outlet get a => outlets[0];

  /// Alternate output (routed when random roll is greater than or equal to [probability]).
  Outlet get b => outlets[1];

  /// Semantic alias for outlet [a].
  Outlet get pass => outlets[0];

  /// Semantic alias for outlet [b].
  Outlet get alt => outlets[1];

  @override
  List<Object?> get fixedProps => [seed];

  @override
  List<Object?> get dynamicProps => [probability];

  @override
  ChanceProcessor createProcessor() => ChanceProcessor(
    probability: probability.valueOrNull ?? 0.5,
    seed: seed,
  );

  @override
  ChanceParams get params => (
    probability: probability.valueOrNull,
  );
}

class ChanceProcessor implements AudioProcessor {
  ChanceProcessor({
    this.probability = 0.5,
    int? seed,
  }) : _random = math.Random(seed);

  /// Probability threshold (0.0 to 1.0) of routing to outlet A.
  ///
  /// * `1.0`: 100% of events route to [a] (0% to [b]).
  /// * `0.0`: 100% of events route to [b] (0% to [a]).
  /// * `0.5`: Unbiased 50/50 coin flip.
  double probability;

  final math.Random _random;

  /// Tracks the input state in the previous sample to detect rising edges.
  bool _lastInput = false;

  /// Stores the outcome of the most recent coin flip while input is held high.
  bool _routeToA = true;

  @override
  void update(Object params) {
    final p = params as ChanceParams;
    if (p.probability != null) {
      probability = p.probability!;
    }
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final inBuffer = inputs[Chance.inputInlet];
    final outA = outputs[0];
    final outB = outputs[1];

    final double p = probability.fastClamp(0.0, 1.0);
    bool lastInput = _lastInput;
    bool routeToA = _routeToA;

    for (int i = 0; i < inBuffer.length; i++) {
      final double inSample = inBuffer[i];
      final bool inputHigh = inSample > 0.0;

      // Rising-edge trap:
      // A new musical event (trigger or gate) begins ONLY on the transition
      // from low (<= 0.0) to high (> 0.0). We roll a new random decision only
      // at this exact instant.
      if (!lastInput && inputHigh) {
        // Latch the routing decision for this event:
        // math.Random.nextDouble() returns a uniform double in [0.0, 1.0).
        routeToA = _random.nextDouble() < p;
      }
      lastInput = inputHigh;

      // Signal passthrough:
      // If the input is currently high, pass the exact incoming sample through
      // to the chosen outlet, while sending silence (0.0) to the other outlet.
      // If the input is low, both outlets are silent.
      if (inputHigh) {
        if (routeToA) {
          outA[i] = inSample;
          outB[i] = 0.0;
        } else {
          outA[i] = 0.0;
          outB[i] = inSample;
        }
      } else {
        outA[i] = 0.0;
        outB[i] = 0.0;
      }
    }

    _lastInput = lastInput;
    _routeToA = routeToA;
  }
}

extension OutletChanceExtension on Outlet {
  /// Routes this trigger or gate outlet through a probabilistic [Chance] gate.
  Chance chance([double probability = 0.5, int? seed]) => Chance(
    input: this,
    probability: .value(probability),
    seed: seed,
  );
}
