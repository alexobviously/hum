import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Available non-linear transfer curves for [Saturator].
enum SaturationMode {
  /// Hyperbolic tangent saturation.
  ///
  /// Classic analog model representing magnetic tape and transistor saturation.
  /// Smoothly limits peaks towards +/-1.0 while introducing musical odd harmonics.
  tanh,

  /// Bram de Jong polynomial soft-clipping: `x * (1.5 - 0.5 * x^2)` for `|x| <= 1.0`.
  ///
  /// Computationally efficient, C1-continuous soft-clipper with a horizontal
  /// derivative at threshold and zero transcendental function overhead.
  cubic,

  /// Algebraic soft-clipper: `x / sqrt(1.0 + x^2)`.
  ///
  /// Gentle, progressive saturation curve with smooth dynamic compression.
  algebraic,

  /// Arctangent saturation: `(2 / pi) * atan((pi / 2) * x)`.
  ///
  /// Normalized unit-slope curve providing musical compression and warm harmonics.
  atan,

  /// Sinusoidal wavefolding: `sin((pi / 2) * x)`.
  ///
  /// Inverts and folds peaks inward when driven beyond the ceiling, producing
  /// metallic, harmonic-rich West Coast synthesis timbres.
  wavefold,
}

typedef SaturatorParams = ({
  double? drive,
  double? bias,
  double? mix,
  SaturationMode mode,
  bool dcBlock,
});

/// An [AudioNode] that provides non-linear saturation, waveshaping, and asymmetric
/// tube warmth.
///
/// Supports:
/// - **Drive**: Input amplification factor driving the signal into the non-linear curve.
/// - **Bias**: Asymmetric DC bias operating point (`[-1.0, 1.0]`) to inject musical even
///   harmonics (2nd, 4th - tube triode warmth). Crucially, the processor applies DC
///   correction so silence remains at 0.0 without DC offset.
/// - **Mix**: Parallel dry/wet blending (`0.0` = 100% dry, `0.5` = 50/50, `1.0` = 100% wet).
/// - **Multiple Modes**: [SaturationMode.tanh], [SaturationMode.cubic],
///   [SaturationMode.algebraic], [SaturationMode.atan], and [SaturationMode.wavefold].
/// - Audio-rate modulation for [drive], [bias], and [mix].
class const Saturator({
  required final List<Outlet> channels,
  final ControlParam<double> drive = const .value(1.0),
  final ControlParam<double> bias = const .value(0.0),
  final ControlParam<double> mix = const .value(1.0),
  final SaturationMode mode = .tanh,
  final bool dcBlock = false,
}) extends AudioNode<SaturatorProcessor> {
  factory mono(
    Outlet input, {
    ControlParam<double> drive = const .value(1.0),
    ControlParam<double> bias = const .value(0.0),
    ControlParam<double> mix = const .value(1.0),
    SaturationMode mode = .tanh,
    bool dcBlock = false,
  }) => Saturator(
    channels: [input],
    drive: drive,
    bias: bias,
    mix: mix,
    mode: mode,
    dcBlock: dcBlock,
  );

  factory stereo(
    Outlet leftInput,
    Outlet rightInput, {
    ControlParam<double> drive = const .value(1.0),
    ControlParam<double> bias = const .value(0.0),
    ControlParam<double> mix = const .value(1.0),
    SaturationMode mode = .tanh,
    bool dcBlock = false,
  }) => Saturator(
    channels: [leftInput, rightInput],
    drive: drive,
    bias: bias,
    mix: mix,
    mode: mode,
    dcBlock: dcBlock,
  );

  /// Something like warm tube triode saturation with asymmetric bias.
  factory tube(
    Outlet input, {
    ControlParam<double> drive = const .value(2.0),
    ControlParam<double> bias = const .value(0.3),
    ControlParam<double> mix = const .value(1.0),
    bool dcBlock = true,
  }) => .mono(
    input,
    drive: drive,
    bias: bias,
    mix: mix,
    mode: .cubic,
    dcBlock: dcBlock,
  );

  /// Something like analog tape saturation using hyperbolic tangent.
  factory tape(
    Outlet input, {
    ControlParam<double> drive = const .value(1.5),
    ControlParam<double> mix = const .value(1.0),
    bool dcBlock = true,
  }) => .mono(
    input,
    drive: drive,
    bias: const .value(0.0),
    mix: mix,
    mode: .tanh,
    dcBlock: dcBlock,
  );

  static const driveInlet = 0;
  static const biasInlet = 1;
  static const mixInlet = 2;
  static const audioInletOffset = 3;

  int get numChannels => channels.length;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: driveInlet, source: drive.outletOrNull),
    Inlet(node: this, index: biasInlet, source: bias.outletOrNull),
    Inlet(node: this, index: mixInlet, source: mix.outletOrNull),
    for (int i = 0; i < channels.length; i++)
      Inlet(node: this, index: audioInletOffset + i, source: channels[i]),
  ];

  @override
  List<Outlet> get outlets =>
      List.generate(channels.length, (i) => Outlet(node: this, index: i));

  Outlet get outlet => outlets.first;
  Outlet get left => outlets[0];
  Outlet get right => outlets[1];

  @override
  SaturatorProcessor createProcessor() => SaturatorProcessor(
    numChannels: numChannels,
    drive: drive.valueOrNull,
    bias: bias.valueOrNull,
    mix: mix.valueOrNull,
    mode: mode,
    dcBlock: dcBlock,
  );

  @override
  SaturatorParams get params => (
    drive: drive.valueOrNull,
    bias: bias.valueOrNull,
    mix: mix.valueOrNull,
    mode: mode,
    dcBlock: dcBlock,
  );
}

/// Processor implementing non-linear transfer curves, asymmetric bias, and dry/wet blending.
class SaturatorProcessor({
  required final int numChannels,
  var double? drive = 1.0,
  var double? bias = 0.0,
  var double? mix = 1.0,
  var SaturationMode mode = .tanh,
  var bool dcBlock = false,
}) with DcBlockMixin implements AudioProcessor {
  static const double _twoOverPi = 0.6366197723675814;
  static const double _halfPi = 1.5707963267948966;

  @override
  void update(Object params) {
    final p = params as SaturatorParams;
    drive = p.drive;
    bias = p.bias;
    mix = p.mix;
    mode = p.mode;
    dcBlock = p.dcBlock;
  }

  @pragma('vm:prefer-inline')
  static double _shapeSample(double x, SaturationMode mode) {
    switch (mode) {
      case .tanh:
        if (x > 20.0) return 1.0;
        if (x < -20.0) return -1.0;
        final e2x = math.exp(2.0 * x);
        return (e2x - 1.0) / (e2x + 1.0);
      case .cubic:
        if (x <= -1.0) return -1.0;
        if (x >= 1.0) return 1.0;
        return x * (1.5 - 0.5 * x * x);
      case .algebraic:
        return x / math.sqrt(1.0 + x * x);
      case .atan:
        return _twoOverPi * math.atan(_halfPi * x);
      case .wavefold:
        return math.sin(_halfPi * x);
    }
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;

    final staticDrive = drive;
    final staticBias = bias;
    final staticMix = mix;

    final driveBuf = staticDrive == null ? inputs[Saturator.driveInlet] : null;
    final biasBuf = staticBias == null ? inputs[Saturator.biasInlet] : null;
    final mixBuf = staticMix == null ? inputs[Saturator.mixInlet] : null;

    final defaultDrive = staticDrive ?? 1.0;
    final defaultBias = staticBias ?? 0.0;
    final defaultMix = staticMix ?? 1.0;

    // Fast path: static scalar parameters
    if (driveBuf == null && biasBuf == null && mixBuf == null) {
      final d = defaultDrive;
      final b = defaultBias;
      final dcOffset = b == 0.0 ? 0.0 : _shapeSample(b, mode);
      final (dryGain, wetGain) = linearMix(defaultMix);
      final isFullWet = defaultMix >= 1.0;

      for (int c = 0; c < numChannels; c++) {
        final inBuf = inputs[Saturator.audioInletOffset + c];
        final outBuf = outputs[c];

        if (isFullWet) {
          if (b == 0.0) {
            // Pure symmetric 100% wet saturation
            for (int i = 0; i < length; i++) {
              outBuf[i] = _shapeSample(inBuf[i] * d, mode);
            }
          } else {
            // Asymmetric 100% wet saturation with DC correction
            for (int i = 0; i < length; i++) {
              outBuf[i] = _shapeSample(inBuf[i] * d + b, mode) - dcOffset;
            }
          }
        } else {
          // Parallel dry/wet blend
          for (int i = 0; i < length; i++) {
            final x = inBuf[i];
            final wet = b == 0.0
                ? _shapeSample(x * d, mode)
                : _shapeSample(x * d + b, mode) - dcOffset;
            outBuf[i] = x * dryGain + wet * wetGain;
          }
        }
      }
    } else {
      // Audio-rate modulated path
      for (int c = 0; c < numChannels; c++) {
        final inBuf = inputs[Saturator.audioInletOffset + c];
        final outBuf = outputs[c];

        for (int i = 0; i < length; i++) {
          final d = driveBuf != null ? driveBuf[i] : defaultDrive;
          final b = biasBuf != null ? biasBuf[i] : defaultBias;
          final m = mixBuf != null ? mixBuf[i] : defaultMix;

          final dcOffset = b == 0.0 ? 0.0 : _shapeSample(b, mode);
          final x = inBuf[i];
          final wet = _shapeSample(x * d + b, mode) - dcOffset;

          if (m >= 1.0) {
            outBuf[i] = wet;
          } else {
            final (dryGain, wetGain) = linearMix(m);
            outBuf[i] = x * dryGain + wet * wetGain;
          }
        }
      }
    }

    if (dcBlock) {
      final sr = context.sampleRate.toDouble();
      for (int c = 0; c < numChannels; c++) {
        applyDcBlock(outputs[c], c, length, sampleRate: sr);
      }
    }
  }
}

extension OutletSaturatorExtension on Outlet {
  /// Applies non-linear saturation / waveshaping to this outlet.
  Saturator saturate({
    ControlParam<double> drive = const .value(1.0),
    ControlParam<double> bias = const .value(0.0),
    ControlParam<double> mix = const .value(1.0),
    SaturationMode mode = .tanh,
    bool dcBlock = false,
  }) => Saturator.mono(
    this,
    drive: drive,
    bias: bias,
    mix: mix,
    mode: mode,
    dcBlock: dcBlock,
  );
}
