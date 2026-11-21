import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef AbsParams = ();

/// An [AudioNode] that computes the absolute value (full-wave rectification)
/// of incoming audio [channels] (`out = abs(in)`).
///
/// Flips negative excursions positive, converting bipolar audio into unipolar pulses.
/// Useful for frequency doubling, waveshaping distortion, and envelope detection.
class Abs({required final List<Outlet> channels})
    extends AudioNode<AbsProcessor> {
  factory mono(Outlet input) => Abs(channels: [input]);

  factory stereo(Outlet leftInput, Outlet rightInput) =>
      Abs(channels: [leftInput, rightInput]);

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
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => const [];

  @override
  AbsProcessor createProcessor() => AbsProcessor(numChannels: channels.length);

  @override
  AbsParams get params => ();
}

class AbsProcessor implements AudioProcessor {
  final int numChannels;

  AbsProcessor({required this.numChannels});

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
        final sample = inBuf[i];
        outBuf[i] = sample < 0.0 ? -sample : sample;
      }
    }
  }
}

extension OutletAbsExtension on Outlet {
  /// Returns a new [Outlet] that computes the absolute value of
  /// this signal (`out = abs(this)`).
  Outlet get abs => Abs.mono(this).outlet;
}
