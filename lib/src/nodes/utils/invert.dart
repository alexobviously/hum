import 'dart:typed_data';

import 'package:hum/hum.dart';

/// An [AudioNode] that inverts the polarity of incoming audio [channels] (`out = -in`).
///
/// Useful for: phase cancellation, differential signal routing,
/// mid/side matrixing, and feedback comb filter inversion.
class const Invert({required final List<Outlet> channels})
    extends AudioNode<InvertProcessor> {
  factory mono(Outlet input) => Invert(channels: [input]);

  factory stereo(Outlet leftInput, Outlet rightInput) =>
      Invert(channels: [leftInput, rightInput]);

  @override
  List<Inlet> get inlets => List.generate(
    channels.length,
    (i) => Inlet(node: this, index: i, source: channels[i]),
  );

  @override
  List<Outlet> get outlets =>
      List.generate(channels.length, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;

  @override
  InvertProcessor createProcessor() =>
      InvertProcessor(numChannels: channels.length);

  @override
  () get params => ();
}

class InvertProcessor implements AudioProcessor {
  final int numChannels;

  InvertProcessor({required this.numChannels});

  @override
  void update(Object params) {}

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    for (int c = 0; c < numChannels; c++) {
      final inBuf = inputs[c];
      final outBuf = outputs[c];

      for (int i = 0; i < context.vectorSize; i++) {
        outBuf[i] = -inBuf[i];
      }
    }
  }
}

extension OutletInvertExtension on Outlet {
  /// Returns a new [Outlet] with its polarity inverted (`out = -this`).
  Outlet operator -() => Invert.mono(this).outlet;
}
