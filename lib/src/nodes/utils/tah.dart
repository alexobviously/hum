import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef TahParams = ({double threshold, bool activeHigh});
typedef TrackAndHold = Tah;

/// Track and hold.
///
/// While [gate] is active (by default, `gate > threshold`), incoming samples
/// from each channel in [channels] pass straight through in real-time (**track** mode).
///
/// When [gate] goes inactive (`gate <= threshold`), the latest sample received is
/// frozen and held until [gate] becomes active again (**hold** mode).
///
/// If [activeHigh] is false, the logic is inverted (tracks while low, holds while high).
///
/// Prior to any tracking, the initial held value is 0.0.
class const Tah({
  required final Outlet gate,
  required final List<Outlet> channels,
  final double threshold = 0.5,
  final bool activeHigh = true,
}) implements AudioNode<TahProcessor> {
  static const gateInlet = 0;

  factory mono({
    required Outlet gate,
    required Outlet input,
    double threshold = 0.5,
    bool activeHigh = true,
  }) => Tah(
    gate: gate,
    channels: [input],
    threshold: threshold,
    activeHigh: activeHigh,
  );

  factory stereo({
    required Outlet gate,
    required Outlet leftInput,
    required Outlet rightInput,
    double threshold = 0.5,
    bool activeHigh = true,
  }) => Tah(
    gate: gate,
    channels: [leftInput, rightInput],
    threshold: threshold,
    activeHigh: activeHigh,
  );

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: gateInlet, source: gate),
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
  TahProcessor createProcessor() => TahProcessor(
    numChannels: channels.length,
    threshold: threshold,
    activeHigh: activeHigh,
  );

  @override
  TahParams get params => (threshold: threshold, activeHigh: activeHigh);
}

class TahProcessor({
  required final int numChannels,
  required var double threshold,
  required var bool activeHigh,
}) implements AudioProcessor {
  final _heldValues = Float32List(numChannels);

  @override
  void update(Object params) {
    params = params as TahParams;
    threshold = params.threshold;
    activeHigh = params.activeHigh;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final gateBuf = inputs[Tah.gateInlet];
    final thresh = threshold;
    final isHigh = activeHigh;

    for (int i = 0; i < length; i++) {
      final gateVal = gateBuf[i];
      final isTracking = isHigh ? (gateVal > thresh) : (gateVal <= thresh);

      if (isTracking) {
        for (int c = 0; c < numChannels; c++) {
          final s = inputs[c + 1][i];
          _heldValues[c] = s;
          outputs[c][i] = s;
        }
      } else {
        for (int c = 0; c < numChannels; c++) {
          outputs[c][i] = _heldValues[c];
        }
      }
    }
  }
}

extension OutletTahExtension on Outlet {
  /// Tracks and holds this outlet using [gate].
  Tah tah(
    Outlet gate, {
    double threshold = 0.5,
    bool activeHigh = true,
  }) => Tah(
    gate: gate,
    channels: [this],
    threshold: threshold,
    activeHigh: activeHigh,
  );
}
