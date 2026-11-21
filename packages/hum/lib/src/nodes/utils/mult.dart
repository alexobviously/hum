import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef MultParams = ({double? value, double interpTime});

/// An [AudioNode] that multiplies incoming audio [channels] by a [value].
///
/// If [value] is a static number, this scales the signal amplitude.
/// If [value] is an [Outlet], this performs audio-rate vector multiplication
/// (4-quadrant ring modulation / amplitude modulation).
class Mult({
  required final ControlParam<double> value,
  required final List<Outlet> channels,
  final double interpTime = 0.02,
}) extends AudioNode<MultProcessor> {
  factory mono({
    required ControlParam<double> value,
    required Outlet input,
    double interpTime = 0.02,
  }) => Mult(value: value, channels: [input], interpTime: interpTime);

  factory stereo({
    required ControlParam<double> value,
    required Outlet leftInput,
    required Outlet rightInput,
    double interpTime = 0.02,
  }) => Mult(
    value: value,
    channels: [leftInput, rightInput],
    interpTime: interpTime,
  );

  static const valueInlet = 0;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: valueInlet, source: value.outletOrNull),
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
  MultProcessor createProcessor() => MultProcessor(
    value: value.valueOrNull,
    numChannels: channels.length,
    interpTime: interpTime,
  );

  @override
  MultParams get params => (
    value: value.valueOrNull,
    interpTime: interpTime,
  );

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeParamError(param: 'channels', error: 'must not be empty'),
    if (interpTime < 0)
      const AudioNodeParamError(
        param: 'interpTime',
        error: 'must be non-negative',
      ),
  ];

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => [value, interpTime];
}

class MultProcessor implements AudioProcessor {
  final int numChannels;
  double? value;
  double interpTime;

  MultProcessor({
    required this.value,
    required this.numChannels,
    this.interpTime = 0.02,
  });

  // To prevent 'zipper' noises when adjusting value sharply
  late final SmoothedValue _smoother = SmoothedValue(value ?? 0.0);

  // Cached SIMD vector views
  // TODO: harden with engine epochs once available
  Float32List? _lastOut;
  List<SimdList>? _out4;
  List<SimdList>? _in4;
  SimdList? _val4;

  @override
  void update(Object params) {
    final p = params as MultParams;
    final oldValue = value;
    value = p.value;
    interpTime = p.interpTime;

    if (p.value != null) {
      if (oldValue == null || interpTime <= 0.0) {
        _smoother.snapTo(p.value!);
      } else {
        _smoother.setTarget(p.value!);
      }
    }
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    if (numChannels == 0) return;

    final value = this.value;
    final vs = context.vectorSize;

    // Lazy initialization, happens in first block
    // TODO: harden with engine epochs once available
    if (!identical(_lastOut, outputs[0])) {
      _lastOut = outputs[0];
      _out4 = [
        for (int c = 0; c < numChannels; c++) SIMD.view(outputs[c], vs),
      ];
      _in4 = [
        for (int c = 0; c < numChannels; c++) SIMD.view(inputs[c + 1], vs),
      ];
      _val4 = SIMD.view(inputs[Mult.valueInlet], vs);
    }

    final out4 = _out4!;
    final in4 = _in4!;

    if (value != null) {
      _smoother.configure(
        sampleRate: context.sampleRate.toDouble(),
        rampTime: interpTime,
      );

      if (_smoother.isSettled) {
        final gain = _smoother.current;
        for (int c = 0; c < numChannels; c++) {
          SIMD.scale(out4[c], in4[c], gain, vs);
        }
      } else {
        // 'Currently interpolating' transient branch (~20ms) - kept scalar
        for (int i = 0; i < vs; i++) {
          final gain = _smoother.next();
          for (int c = 0; c < numChannels; c++) {
            outputs[c][i] = inputs[c + 1][i] * gain;
          }
        }
      }
    } else {
      final val4 = _val4!;
      for (int c = 0; c < numChannels; c++) {
        SIMD.multiply(out4[c], in4[c], val4, vs);
      }
    }
  }
}

extension OutletMultExtension on Outlet {
  /// Multiplies [other] signal from this outlet: `this * other`.
  Outlet operator *(Outlet other) =>
      Mult.mono(input: this, value: .signal(other)).outlet;

  /// Multiplies a constant scalar [value] from this outlet.
  Mult mult(double value, {double interpTime = 0.02}) =>
      Mult.mono(input: this, value: .value(value), interpTime: interpTime);
}
