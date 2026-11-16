import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

typedef VinylNoiseParams = ({
  double? crackle,
  double? hiss,
  double? warp,
  double? density,
  double rpm,
});

/// A physical emulation of vinyl surface noise, dust crackle, and rotational warp.
///
/// Models the acoustic and mechanical characteristics of vinyl record playback:
/// - **Surface Hiss / Friction**: Continuous broadband noise shaped by PVC groove
///   damping and stylus compliance with subtle stereo decorrelation.
/// - **Dust Crackle & Pops**: Poisson point process triggering damped mechanical
///   cantilever micro-resonances with randomized power-law amplitudes and stereo
///   placement.
/// - **Rotational Warp / Wow**: Cyclic rotational amplitude modulation and
///   sub-bass motor rumble swell.
class const VinylNoise({
  final ControlParam<double> crackle = const .value(0.3),
  final ControlParam<double> hiss = const .value(0.15),
  final ControlParam<double> warp = const .value(0.2),
  final ControlParam<double> density = const .value(25.0),
  final double rpm = 33.333333333333336,
  final int? seed,
}) extends AudioNode<VinylNoiseProcessor> {
  const VinylNoise.rpm33({
    ControlParam<double> crackle = const .value(0.3),
    ControlParam<double> hiss = const .value(0.15),
    ControlParam<double> warp = const .value(0.2),
    ControlParam<double> density = const .value(25.0),
    int? seed,
  }) : this(
         crackle: crackle,
         hiss: hiss,
         warp: warp,
         density: density,
         rpm: 33.333333333333336,
         seed: seed,
       );

  const VinylNoise.rpm45({
    ControlParam<double> crackle = const .value(0.3),
    ControlParam<double> hiss = const .value(0.15),
    ControlParam<double> warp = const .value(0.2),
    ControlParam<double> density = const .value(25.0),
    int? seed,
  }) : this(
         crackle: crackle,
         hiss: hiss,
         warp: warp,
         density: density,
         rpm: 45.0,
         seed: seed,
       );

  const VinylNoise.rpm78({
    ControlParam<double> crackle = const .value(0.3),
    ControlParam<double> hiss = const .value(0.15),
    ControlParam<double> warp = const .value(0.2),
    ControlParam<double> density = const .value(25.0),
    int? seed,
  }) : this(
         crackle: crackle,
         hiss: hiss,
         warp: warp,
         density: density,
         rpm: 78.26,
         seed: seed,
       );

  static const crackleInlet = 0;
  static const hissInlet = 1;
  static const warpInlet = 2;
  static const densityInlet = 3;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: crackleInlet, source: crackle.outletOrNull),
    Inlet(node: this, index: hissInlet, source: hiss.outletOrNull),
    Inlet(node: this, index: warpInlet, source: warp.outletOrNull),
    Inlet(node: this, index: densityInlet, source: density.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: 0),
    Outlet(node: this, index: 1),
  ];

  /// Left channel outlet.
  Outlet get left => outlets[0];

  /// Right channel outlet.
  Outlet get right => outlets[1];

  /// Mono outlet (left channel).
  Outlet get outlet => outlets[0];

  @override
  List<Object?> get fixedProps => [seed];

  @override
  List<Object?> get dynamicProps => [crackle, hiss, warp, density, rpm];

  @override
  VinylNoiseProcessor createProcessor() => VinylNoiseProcessor(
    crackle: crackle.valueOrNull,
    hiss: hiss.valueOrNull,
    warp: warp.valueOrNull,
    density: density.valueOrNull,
    rpm: rpm,
    seed: seed,
  );

  @override
  VinylNoiseParams get params => (
    crackle: crackle.valueOrNull,
    hiss: hiss.valueOrNull,
    warp: warp.valueOrNull,
    density: density.valueOrNull,
    rpm: rpm,
  );

  @override
  List<AudioNodeError> get errors => [
    if (crackle.valueOrNull != null && crackle.valueOrNull! < 0.0)
      AudioNodeParamError(
        param: 'crackle',
        error: 'Crackle gain must be non-negative',
      ),
    if (hiss.valueOrNull != null && hiss.valueOrNull! < 0.0)
      AudioNodeParamError(
        param: 'hiss',
        error: 'Hiss gain must be non-negative',
      ),
    if (warp.valueOrNull != null &&
        (warp.valueOrNull! < 0.0 || warp.valueOrNull! > 1.0))
      AudioNodeParamError(
        param: 'warp',
        error: 'Warp amount must be between 0.0 and 1.0',
      ),
    if (density.valueOrNull != null && density.valueOrNull! < 0.0)
      AudioNodeParamError(
        param: 'density',
        error: 'Click density must be non-negative',
      ),
    if (rpm <= 0.0)
      AudioNodeParamError(
        param: 'rpm',
        error: 'Turntable RPM must be positive',
      ),
  ];
}

/// DSP processor synthesizing physical vinyl groove hiss, Poisson crackle, and rotational warp.
class VinylNoiseProcessor implements AudioProcessor {
  VinylNoiseProcessor({
    this.crackle = 0.3,
    this.hiss = 0.15,
    this.warp = 0.2,
    this.density = 25.0,
    this.rpm = 33.333333333333336,
    int? seed,
  }) : _state = (seed == null || seed == 0) ? 0x6D2B79F5 : seed & 0xFFFFFFFF;

  double? crackle;
  double? hiss;
  double? warp;
  double? density;
  double rpm;

  int _state;

  // Surface hiss filters (1-pole lowpass + 1-pole DC/rumble highpass)
  double _hissLpL = 0.0;
  double _hissLpR = 0.0;
  double _hissHpL = 0.0;
  double _hissHpR = 0.0;

  // Click needle resonators (2-pole SVF bandpass per channel)
  double _clickS1L = 0.0;
  double _clickS2L = 0.0;
  double _clickS1R = 0.0;
  double _clickS2R = 0.0;

  // Warp rotation phase [0.0, 1.0)
  double _warpPhase = 0.0;

  // Precomputed filter coefficients
  double _lastSampleRate = 0.0;
  double _alphaLp = 0.0;
  double _alphaHp = 0.0;
  double _clickA1 = 0.0;
  double _clickA2 = 0.0;
  double _clickA3 = 0.0;

  @override
  void update(Object params) {
    params = params as VinylNoiseParams;
    crackle = params.crackle;
    hiss = params.hiss;
    warp = params.warp;
    density = params.density;
    rpm = params.rpm;
  }

  void _updateCoefficients(double sampleRate) {
    if (sampleRate == _lastSampleRate) return;
    _lastSampleRate = sampleRate;

    // Hiss lowpass cutoff around 3500 Hz (warm PVC roll-off)
    final wLp = 2.0 * math.pi * 3500.0 / sampleRate;
    _alphaLp = 1.0 - math.exp(-wLp);

    // Hiss highpass cutoff around 70 Hz (cut sub-audible DC)
    final wHp = 2.0 * math.pi * 70.0 / sampleRate;
    _alphaHp = 1.0 - math.exp(-wHp);

    // Cantilever click resonance: center 3200 Hz, Q = 2.5
    final wClick = 2.0 * math.pi * 3200.0 / sampleRate;
    final g = math.tan(wClick * 0.5);
    final k = 1.0 / 2.5; // damping factor = 0.4
    _clickA1 = 1.0 / (1.0 + g * (g + k));
    _clickA2 = g * _clickA1;
    _clickA3 = g * _clickA2;
  }

  double _nextUniform() {
    _state ^= (_state << 13) & 0xFFFFFFFF;
    _state ^= _state >> 17;
    _state ^= (_state << 5) & 0xFFFFFFFF;
    return (_state & 0xFFFFFFFF) / 4294967296.0;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final sampleRate = context.sampleRate.toDouble();
    _updateCoefficients(sampleRate);

    final outL = outputs[0];
    final outR = outputs[1];
    final vectorSize = context.vectorSize;

    final crackleBuffer = crackle == null
        ? inputs[VinylNoise.crackleInlet]
        : null;
    final hissBuffer = hiss == null ? inputs[VinylNoise.hissInlet] : null;
    final warpBuffer = warp == null ? inputs[VinylNoise.warpInlet] : null;
    final densityBuffer = density == null
        ? inputs[VinylNoise.densityInlet]
        : null;

    final baseCrackle = crackle ?? 0.0;
    final baseHiss = hiss ?? 0.0;
    final baseWarp = warp ?? 0.0;
    final baseDensity = density ?? 25.0;

    final rotDelta = (rpm / 60.0) / sampleRate;
    final invSampleRate = 1.0 / sampleRate;

    for (int i = 0; i < vectorSize; i++) {
      final cGain = crackleBuffer != null ? crackleBuffer[i] : baseCrackle;
      final hGain = hissBuffer != null ? hissBuffer[i] : baseHiss;
      final wAmount = warpBuffer != null ? warpBuffer[i] : baseWarp;
      final dRate = densityBuffer != null ? densityBuffer[i] : baseDensity;

      // 1. Warp / Rotation modulation
      _warpPhase += rotDelta;
      if (_warpPhase >= 1.0) _warpPhase -= 1.0;

      // Smooth cosine hump once per revolution
      final warpAngle = 2.0 * math.pi * _warpPhase;
      final cosVal = math.cos(warpAngle);
      final warpEnv = cosVal > 0.0 ? cosVal * cosVal : 0.0;

      // Subtle motor/warp rumble (32 Hz cycle modulated by warp bump)
      final rumble = math.sin(warpAngle * 10.0) * warpEnv * wAmount * 0.08;

      // Surface hiss swell during warp
      final hissMod = 1.0 + wAmount * 0.6 * (warpEnv - 0.25);

      // 2. Surface Hiss (broadband groove friction with stereo decorrelation)
      final rawNoiseL = _nextUniform() * 2.0 - 1.0;
      final rawNoiseR = _nextUniform() * 2.0 - 1.0;

      _hissLpL += _alphaLp * (rawNoiseL - _hissLpL);
      _hissLpR += _alphaLp * (rawNoiseR - _hissLpR);

      final hpL = _hissLpL - _hissHpL;
      _hissHpL += _alphaHp * hpL;

      final hpR = _hissLpR - _hissHpR;
      _hissHpR += _alphaHp * hpR;

      // 70% mono + 30% decorrelated difference
      final monoHiss = 0.5 * (hpL + hpR);
      final diffHiss = 0.5 * (hpL - hpR);

      final finalHissL = (monoHiss + 0.4 * diffHiss) * hGain * hissMod;
      final finalHissR = (monoHiss - 0.4 * diffHiss) * hGain * hissMod;

      // 3. Poisson Dust Crackle & Pops
      double impulseL = 0.0;
      double impulseR = 0.0;

      final effectiveDensity = dRate > 0.0 ? dRate : 0.0;
      final pClick =
          (effectiveDensity * invSampleRate) * (1.0 + wAmount * warpEnv);

      if (cGain > 0.0 && _nextUniform() < pClick) {
        // Cubic distribution: mostly small ticks, occasional distinct pops
        final u = _nextUniform();
        final size = u * u * u;
        final sign = _nextUniform() > 0.5 ? 1.0 : -1.0;
        final clickAmp = sign * (0.05 + 0.95 * size) * cGain;

        // Random stereo deflection across the groove
        final pan = (_nextUniform() - 0.5) * 1.4; // [-0.7, 0.7]
        impulseL = clickAmp * (0.5 - 0.5 * pan);
        impulseR = clickAmp * (0.5 + 0.5 * pan);
      }

      // 4. 2-pole Cantilever Resonance Filter (damped mechanical click)
      final v3L = impulseL - _clickS2L;
      final v1L = _clickA1 * _clickS1L + _clickA2 * v3L;
      final v2L = _clickS2L + _clickA2 * _clickS1L + _clickA3 * v3L;
      _clickS1L = 2.0 * v1L - _clickS1L;
      _clickS2L = 2.0 * v2L - _clickS2L;

      final v3R = impulseR - _clickS2R;
      final v1R = _clickA1 * _clickS1R + _clickA2 * v3R;
      final v2R = _clickS2R + _clickA2 * _clickS1R + _clickA3 * v3R;
      _clickS1R = 2.0 * v1R - _clickS1R;
      _clickS2R = 2.0 * v2R - _clickS2R;

      // Sum everything together into Left and Right channels
      outL[i] = (finalHissL + v1L + rumble);
      outR[i] = (finalHissR + v1R + rumble);
    }

    // Anti-denormal flushing
    if (_hissLpL.abs() < 1e-15) _hissLpL = 0.0;
    if (_hissLpR.abs() < 1e-15) _hissLpR = 0.0;
    if (_hissHpL.abs() < 1e-15) _hissHpL = 0.0;
    if (_hissHpR.abs() < 1e-15) _hissHpR = 0.0;
    if (_clickS1L.abs() < 1e-15) _clickS1L = 0.0;
    if (_clickS2L.abs() < 1e-15) _clickS2L = 0.0;
    if (_clickS1R.abs() < 1e-15) _clickS1R = 0.0;
    if (_clickS2R.abs() < 1e-15) _clickS2R = 0.0;
  }
}

/// Convenience extensions for overlaying vinyl noise directly onto signals.
extension VinylNoiseOverlayExtension on Outlet {
  /// Overlays vinyl surface noise, crackle, and rotational warp onto this mono outlet.
  Outlet addVinyl({
    ControlParam<double> crackle = const .value(0.3),
    ControlParam<double> hiss = const .value(0.15),
    ControlParam<double> warp = const .value(0.2),
    ControlParam<double> density = const .value(25.0),
    double rpm = 33.333333333333336,
    int? seed,
  }) {
    final vinyl = VinylNoise(
      crackle: crackle,
      hiss: hiss,
      warp: warp,
      density: density,
      rpm: rpm,
      seed: seed,
    );
    return this + vinyl.left;
  }
}

extension StereoVinylNoiseOverlayExtension on (Outlet, Outlet) {
  /// Overlays stereo vinyl surface noise, crackle, and rotational warp onto
  /// this stereo outlet pair.
  (Outlet, Outlet) addVinyl({
    ControlParam<double> crackle = const .value(0.3),
    ControlParam<double> hiss = const .value(0.15),
    ControlParam<double> warp = const .value(0.2),
    ControlParam<double> density = const .value(25.0),
    double rpm = 33.333333333333336,
    int? seed,
  }) {
    final vinyl = VinylNoise(
      crackle: crackle,
      hiss: hiss,
      warp: warp,
      density: density,
      rpm: rpm,
      seed: seed,
    );
    return ($1 + vinyl.left, $2 + vinyl.right);
  }
}
