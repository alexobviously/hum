import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef FreeverbParams = ({
  double? roomSize,
  double? damp,
  double? width,
  double? mix,
});

/// Jezar's classic Freeverb algorithmic stereo reverberator.
///
/// Freeverb implements a Schroeder-Moorer reverberation topology composed of:
/// - 8 parallel Lowpass-Feedback Comb Filters (LBCF) per channel with prime delay lengths
/// - 4 series Allpass Filters per channel for high-density spatial diffusion
/// - Cross-mixed stereo decorrelation via stereo spread delay offsets and width control
///
/// See also:
/// - Freeverb original C++ reference: https://ccrma.stanford.edu/~jos/pasp/Freeverb.html
class Freeverb({
  required final List<Outlet> inputs,
  final ControlParam<double> roomSize = const .value(0.5),
  final ControlParam<double> damp = const .value(0.5),
  final ControlParam<double> width = const .value(1.0),
  final ControlParam<double> mix = const .value(0.0),
}) implements AudioNode<FreeverbProcessor> {
  this
    : assert(
        inputs.length == 1 || inputs.length == 2,
        'Freeverb accepts 1 (mono) or 2 (stereo) audio inputs.',
      );

  /// Note that freeverb always creates stereo output, even with mono input.
  factory mono({
    required Outlet input,
    ControlParam<double> roomSize = const .value(0.5),
    ControlParam<double> damp = const .value(0.5),
    ControlParam<double> width = const .value(1.0),
    ControlParam<double> mix = const .value(0.0),
  }) => Freeverb(
    inputs: [input],
    roomSize: roomSize,
    damp: damp,
    width: width,
    mix: mix,
  );

  factory stereo({
    required Outlet left,
    required Outlet right,
    ControlParam<double> roomSize = const .value(0.5),
    ControlParam<double> damp = const .value(0.5),
    ControlParam<double> width = const .value(1.0),
    ControlParam<double> mix = const .value(0.0),
  }) => Freeverb(
    inputs: [left, right],
    roomSize: roomSize,
    damp: damp,
    width: width,
    mix: mix,
  );

  static const roomSizeInlet = 0;
  static const dampInlet = 1;
  static const widthInlet = 2;
  static const mixInlet = 3;
  static const audioInletOffset = 4;

  int get numInputChannels => inputs.length;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: roomSizeInlet, source: roomSize.outletOrNull),
    Inlet(node: this, index: dampInlet, source: damp.outletOrNull),
    Inlet(node: this, index: widthInlet, source: width.outletOrNull),
    Inlet(node: this, index: mixInlet, source: mix.outletOrNull),
    for (int i = 0; i < inputs.length; i++)
      Inlet(node: this, index: audioInletOffset + i, source: inputs[i]),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: 0),
    Outlet(node: this, index: 1),
  ];

  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  FreeverbProcessor createProcessor() => FreeverbProcessor(
    isStereoInput: inputs.length == 2,
    roomSize: roomSize.valueOrNull,
    damp: damp.valueOrNull,
    width: width.valueOrNull,
    mix: mix.valueOrNull,
  );

  @override
  FreeverbParams get params => (
    roomSize: roomSize.valueOrNull,
    damp: damp.valueOrNull,
    width: width.valueOrNull,
    mix: mix.valueOrNull,
  );
}

/// Internal Lowpass-Feedback Comb Filter (LBCF) with 1-pole damping.
class _CombFilter {
  _CombFilter(int size) : buffer = Float32List(size);

  final Float32List buffer;
  int index = 0;
  double filterStore = 0.0;

  @pragma('vm:prefer-inline')
  double process(double input, double feedback, double damp, double invDamp) {
    final output = buffer[index];

    // 1-pole lowpass filter in feedback path
    final filtered = output * invDamp + filterStore * damp;
    filterStore = filtered.abs() < 1e-15 ? 0.0 : filtered;

    final next = input + filterStore * feedback;
    buffer[index] = next.abs() < 1e-15 ? 0.0 : next;

    if (++index >= buffer.length) {
      index = 0;
    }

    return output;
  }
}

/// Internal Allpass Filter for spatial diffusion.
class _AllpassFilter {
  _AllpassFilter(int size) : buffer = Float32List(size);

  final Float32List buffer;
  int index = 0;

  @pragma('vm:prefer-inline')
  double process(double input) {
    final bufOut = buffer[index];
    final output = -input + bufOut;

    // Standard Freeverb allpass coefficient = 0.5
    final next = input + bufOut * 0.5;
    buffer[index] = next.abs() < 1e-15 ? 0.0 : next;

    if (++index >= buffer.length) {
      index = 0;
    }

    return output;
  }
}

/// Dedicated audio processor implementing the 16-comb + 8-allpass Freeverb engine.
class FreeverbProcessor implements AudioProcessor {
  FreeverbProcessor({
    this.isStereoInput = false,
    this.roomSize = 0.5,
    this.damp = 0.5,
    this.width = 1.0,
    this.mix = 0.0,
  });

  final bool isStereoInput;

  /// Room size [0.0, 1.0] controlling decay feedback.
  double? roomSize;

  /// High-frequency absorption [0.0, 1.0].
  double? damp;

  /// Stereo width [0.0, 1.0] (0.0 = mono, 1.0 = full stereo decorrelation).
  double? width;

  /// Dry/Wet mix in [-1.0, +1.0] (-1.0 = dry, 0.0 = 50/50, +1.0 = 100% wet).
  double? mix;

  int _sampleRate = 0;

  // 8 Parallel Comb Filters per channel (Left & Right)
  List<_CombFilter>? _combsL;
  List<_CombFilter>? _combsR;

  // 4 Series Allpass Diffusers per channel (Left & Right)
  List<_AllpassFilter>? _allpassesL;
  List<_AllpassFilter>? _allpassesR;

  // Canonical Freeverb delay lengths tuned to mutually prime numbers at 44.1 kHz
  static const _baseCombLengths = [
    1116,
    1188,
    1277,
    1356,
    1422,
    1491,
    1557,
    1617,
  ];
  static const _baseAllpassLengths = [556, 441, 341, 225];
  static const int _stereoSpread = 23;

  static const double _fixedGain = 0.015;
  static const double _scaleRoom = 0.28;
  static const double _offsetRoom = 0.7;
  static const double _scaleDamp = 0.4;

  void _ensureBuffers(int sampleRate) {
    if (_sampleRate == sampleRate && _combsL != null) return;
    _sampleRate = sampleRate;

    final double srScale = sampleRate / 44100.0;

    _combsL = [
      for (final len in _baseCombLengths)
        _CombFilter(math.max(1, (len * srScale).round())),
    ];
    _combsR = [
      for (final len in _baseCombLengths)
        _CombFilter(math.max(1, ((len + _stereoSpread) * srScale).round())),
    ];

    _allpassesL = [
      for (final len in _baseAllpassLengths)
        _AllpassFilter(math.max(1, (len * srScale).round())),
    ];
    _allpassesR = [
      for (final len in _baseAllpassLengths)
        _AllpassFilter(math.max(1, ((len + _stereoSpread) * srScale).round())),
    ];
  }

  @override
  void update(Object params) {
    final p = params as FreeverbParams;
    roomSize = p.roomSize;
    damp = p.damp;
    width = p.width;
    mix = p.mix;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    _ensureBuffers(context.sampleRate);

    final vectorSize = context.vectorSize;
    final int audioOffset = inputs.length > Freeverb.audioInletOffset
        ? Freeverb.audioInletOffset
        : 0;

    final staticRoom = roomSize;
    final staticDamp = damp;
    final staticWidth = width;
    final staticMix = mix;

    final roomBuf = staticRoom == null && inputs.length > Freeverb.roomSizeInlet
        ? inputs[Freeverb.roomSizeInlet]
        : null;
    final dampBuf = staticDamp == null && inputs.length > Freeverb.dampInlet
        ? inputs[Freeverb.dampInlet]
        : null;
    final widthBuf = staticWidth == null && inputs.length > Freeverb.widthInlet
        ? inputs[Freeverb.widthInlet]
        : null;
    final mixBuf = staticMix == null && inputs.length > Freeverb.mixInlet
        ? inputs[Freeverb.mixInlet]
        : null;

    final inL = inputs[audioOffset];
    final inR = isStereoInput && inputs.length > audioOffset + 1
        ? inputs[audioOffset + 1]
        : inL;

    final outLeft = outputs[0];
    final outRight = outputs[1];

    final combsL = _combsL!;
    final combsR = _combsR!;
    final allpassesL = _allpassesL!;
    final allpassesR = _allpassesR!;

    final double constRoom = staticRoom ?? 0.5;
    final double constDamp = staticDamp ?? 0.5;
    final double constWidth = staticWidth ?? 1.0;
    final double constMix = staticMix ?? 0.0;

    for (int i = 0; i < vectorSize; i++) {
      final double rSize = (roomBuf == null ? constRoom : roomBuf[i]).clamp(
        0.0,
        1.0,
      );
      final double dVal = (dampBuf == null ? constDamp : dampBuf[i]).clamp(
        0.0,
        1.0,
      );
      final double wVal = (widthBuf == null ? constWidth : widthBuf[i]).clamp(
        0.0,
        1.0,
      );
      final double mVal = (mixBuf == null ? constMix : mixBuf[i]);

      final double feedback = rSize * _scaleRoom + _offsetRoom;
      final double dampCoeff = dVal * _scaleDamp;
      final double invDampCoeff = 1.0 - dampCoeff;

      final (double gainDry, double gainWet) = equalPowerGains(mVal);
      final double wet1 = gainWet * (wVal * 0.5 + 0.5);
      final double wet2 = gainWet * ((1.0 - wVal) * 0.5);

      final double inputSampleL = inL[i] * _fixedGain;
      final double inputSampleR = inR[i] * _fixedGain;

      double accumL = 0.0;
      double accumR = 0.0;

      // 8 Parallel Comb Filters
      for (int c = 0; c < 8; c++) {
        accumL += combsL[c].process(
          inputSampleL,
          feedback,
          dampCoeff,
          invDampCoeff,
        );
        accumR += combsR[c].process(
          inputSampleR,
          feedback,
          dampCoeff,
          invDampCoeff,
        );
      }

      // 4 Series Allpass Diffusers
      for (int a = 0; a < 4; a++) {
        accumL = allpassesL[a].process(accumL);
        accumR = allpassesR[a].process(accumR);
      }

      // Stereo cross-mix and dry/wet blend
      outLeft[i] = inL[i] * gainDry + (accumL * wet1 + accumR * wet2);
      outRight[i] = inR[i] * gainDry + (accumR * wet1 + accumL * wet2);
    }
  }
}
