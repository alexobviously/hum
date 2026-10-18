import 'dart:typed_data';

import 'package:hum/hum.dart';

enum TriggerEdge { rising, falling, both }

typedef SahParams = ({double threshold, TriggerEdge triggerEdge});
typedef SampleAndHold = Sah;

/// Sample and hold.
///
/// When [trigger] crosses [threshold] (in the direction of [triggerEdge]),
/// the latest sample from each input channel is frozen and repeated until
/// the next trigger.
///
/// The initial value is 0.0.
///
/// [trigger]: The trigger signal.
/// [channels]: The input channels to sample.
/// [threshold]: The threshold to trigger on.
/// [triggerEdge]: The direction of the trigger edge.
class const Sah({
  required final Outlet trigger,
  required final List<Outlet> channels,
  final double threshold = 0.5,
  final TriggerEdge triggerEdge = .rising,
}) implements AudioNode<SahProcessor> {
  static const triggerInlet = 0;

  factory mono({
    required Outlet trigger,
    required Outlet input,
    double threshold = 0.5,
    TriggerEdge triggerEdge = .rising,
  }) => Sah(
    trigger: trigger,
    channels: [input],
    threshold: threshold,
    triggerEdge: triggerEdge,
  );

  factory stereo({
    required Outlet trigger,
    required Outlet leftInput,
    required Outlet rightInput,
    double threshold = 0.5,
    TriggerEdge triggerEdge = .rising,
  }) => Sah(
    trigger: trigger,
    channels: [leftInput, rightInput],
    threshold: threshold,
    triggerEdge: triggerEdge,
  );

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: triggerInlet, source: trigger),
    ...List.generate(
      channels.length,
      (i) => Inlet(node: this, index: i + 1, source: channels[i]),
    ),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(channels.length, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;

  @override
  SahProcessor createProcessor() => SahProcessor(
    numChannels: channels.length,
    threshold: threshold,
    triggerEdge: triggerEdge,
  );

  @override
  SahParams get params => (threshold: threshold, triggerEdge: triggerEdge);
}

class SahProcessor({
  required final int numChannels,
  required var double threshold,
  required var TriggerEdge triggerEdge,
}) implements AudioProcessor {
  final _heldValues = Float32List(numChannels);
  double _prevTrigger = 0.0;

  @override
  void update(Object params) {
    params = params as SahParams;
    threshold = params.threshold;
    triggerEdge = params.triggerEdge;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final trigBuf = inputs[Sah.triggerInlet];
    final thresh = threshold;

    for (int i = 0; i < length; i++) {
      final trig = trigBuf[i];
      final isRising = trig > thresh && _prevTrigger <= thresh;
      final isFalling = trig <= thresh && _prevTrigger > thresh;
      final shouldFire = switch (triggerEdge) {
        .rising => isRising,
        .falling => isFalling,
        .both => isRising || isFalling,
      };

      if (shouldFire) {
        for (int c = 0; c < numChannels; c++) {
          _heldValues[c] = inputs[c + 1][i];
        }
      }
      _prevTrigger = trig;

      for (int c = 0; c < numChannels; c++) {
        outputs[c][i] = _heldValues[c];
      }
    }
  }
}

extension OutletSahExtension on Outlet {
  /// Samples and holds this outlet using [trigger].
  Sah sah(
    Outlet trigger, {
    double threshold = 0.5,
    TriggerEdge triggerEdge = .rising,
  }) => Sah(
    trigger: trigger,
    channels: [this],
    threshold: threshold,
    triggerEdge: triggerEdge,
  );
}
