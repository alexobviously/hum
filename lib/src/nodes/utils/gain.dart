import 'dart:typed_data';

import 'package:dsp/dsp.dart';

typedef GainParams = ({double? gain});

class Gain implements AudioNode<GainProcessor> {
  final ControlParam<double> gain;
  final List<Outlet> channels;

  const Gain({required this.gain, required this.channels});

  factory Gain.mono({
    required ControlParam<double> gain,
    required Outlet input,
  }) => Gain(gain: gain, channels: [input]);

  factory Gain.stereo({
    required ControlParam<double> gain,
    required Outlet leftInput,
    required Outlet rightInput,
  }) => Gain(gain: gain, channels: [leftInput, rightInput]);

  static const gainInlet = 0;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: gainInlet, source: gain.outletOrNull),
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
  GainProcessor createProcessor() => GainProcessor(
    gain: gain.valueOrNull,
    numChannels: channels.length,
  );

  @override
  GainParams get params => (gain: gain.valueOrNull);
}

class GainProcessor implements AudioProcessor {
  final int numChannels;
  GainProcessor({required this.gain, required this.numChannels});

  double? gain;

  @override
  void update(Object params) {
    params = params as GainParams;
    gain = params.gain;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final gain = this.gain;

    if (gain != null) {
      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];

        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = inputs[c + 1][i] * gain;
        }
      }
    } else {
      final gainBuffer = inputs[Gain.gainInlet];

      for (int c = 0; c < numChannels; c++) {
        final output = outputs[c];

        for (int i = 0; i < context.vectorSize; i++) {
          output[i] = inputs[c + 1][i] * gainBuffer[i];
        }
      }
    }
  }
}
