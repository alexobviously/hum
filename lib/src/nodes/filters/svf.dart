import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

// https://cytomic.com/files/dsp/SvfLinearTrapOptimised2.pdf
// https://cytomic.com/technical-papers/
// https://www.discodsp.net/VAFilterDesign_2.1.2.pdf

// I did heavily clank this one, but my intent is to come back to it and
// understand it properly once I'm further along with important stuff.

typedef SvfFilterParams = ({double? cutoff, double? resonance});

/// State Variable Filter (SVF) based on Andy Simper's (Cytomic)
/// linear Topology-Preserving Transform (TPT) formulation.
///
/// Features simultaneous lowpass, bandpass, highpass, notch, and unit-gain bandpass
/// outputs with 12 dB/octave slopes and robust audio-rate modulation stability.
class SvfFilter implements AudioNode<SvfFilterProcessor> {
  final Outlet input;
  final ControlParam<double> cutoff;
  final ControlParam<double> resonance;

  const SvfFilter({
    required this.input,
    required this.cutoff,
    this.resonance = const .value(0.7071),
  });

  static const inputInlet = 0;
  static const cutoffInlet = 1;
  static const resonanceInlet = 2;

  static const lowpassOutlet = 0;
  static const bandpassOutlet = 1;
  static const highpassOutlet = 2;
  static const notchOutlet = 3;
  static const unitBandpassOutlet = 4;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: inputInlet, source: input),
    Inlet(node: this, index: cutoffInlet, source: cutoff.outletOrNull),
    Inlet(node: this, index: resonanceInlet, source: resonance.outletOrNull),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: lowpassOutlet),
    Outlet(node: this, index: bandpassOutlet),
    Outlet(node: this, index: highpassOutlet),
    Outlet(node: this, index: notchOutlet),
    Outlet(node: this, index: unitBandpassOutlet),
  ];

  Outlet get lowpass => outlets[lowpassOutlet];
  Outlet get bandpass => outlets[bandpassOutlet];
  Outlet get highpass => outlets[highpassOutlet];
  Outlet get notch => outlets[notchOutlet];
  Outlet get unitBandpass => outlets[unitBandpassOutlet];

  /// Default outlet is lowpass.
  Outlet get outlet => lowpass;

  @override
  SvfFilterProcessor createProcessor() => SvfFilterProcessor(
    cutoff: cutoff.valueOrNull,
    resonance: resonance.valueOrNull,
  );

  @override
  SvfFilterParams get params => (
    cutoff: cutoff.valueOrNull,
    resonance: resonance.valueOrNull,
  );
}

class SvfFilterProcessor implements AudioProcessor {
  double? cutoff;
  double? resonance;

  double _s1 = 0.0;
  double _s2 = 0.0;

  SvfFilterProcessor({
    this.cutoff,
    this.resonance = 0.7071,
  });

  @override
  void update(Object params) {
    params = params as SvfFilterParams;
    cutoff = params.cutoff;
    if (params.resonance != null) {
      resonance = params.resonance;
    }
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final inputBuffer = inputs[SvfFilter.inputInlet];
    final length = context.vectorSize;
    final sampleRate = context.sampleRate.toDouble();
    final maxCutoff = sampleRate * 0.499;
    final piOverSr = math.pi / sampleRate;

    final lpOut = outputs[SvfFilter.lowpassOutlet];
    final bpOut = outputs[SvfFilter.bandpassOutlet];
    final hpOut = outputs[SvfFilter.highpassOutlet];
    final notchOut = outputs[SvfFilter.notchOutlet];
    final ubpOut = outputs[SvfFilter.unitBandpassOutlet];

    double s1 = _s1;
    double s2 = _s2;

    final cutoff = this.cutoff;
    final resonance = this.resonance;

    if (cutoff != null && resonance != null) {
      // Both cutoff and resonance are constant across the block
      final f = cutoff.clamp(1.0, maxCutoff);
      final q = resonance.clamp(0.01, 100.0);
      final g = math.tan(piOverSr * f);
      final k = 1.0 / q;
      final a1 = 1.0 / (1.0 + g * (g + k));
      final a2 = g * a1;

      for (int i = 0; i < length; i++) {
        final v0 = inputBuffer[i];
        final v1 = a1 * s1 + a2 * (v0 - s2);
        final v2 = s2 + g * v1;

        s1 = 2.0 * v1 - s1;
        s2 = 2.0 * v2 - s2;

        final hp = v0 - k * v1 - v2;

        lpOut[i] = v2;
        bpOut[i] = v1;
        hpOut[i] = hp;
        notchOut[i] = hp + v2;
        ubpOut[i] = k * v1;
      }
    } else if (cutoff == null && resonance != null) {
      // Modulated cutoff, constant resonance
      final cutoffBuffer = inputs[SvfFilter.cutoffInlet];
      final q = resonance.clamp(0.01, 100.0);
      final k = 1.0 / q;

      for (int i = 0; i < length; i++) {
        final f = cutoffBuffer[i].clamp(1.0, maxCutoff);
        final g = math.tan(piOverSr * f);
        final a1 = 1.0 / (1.0 + g * (g + k));
        final a2 = g * a1;

        final v0 = inputBuffer[i];
        final v1 = a1 * s1 + a2 * (v0 - s2);
        final v2 = s2 + g * v1;

        s1 = 2.0 * v1 - s1;
        s2 = 2.0 * v2 - s2;

        final hp = v0 - k * v1 - v2;

        lpOut[i] = v2;
        bpOut[i] = v1;
        hpOut[i] = hp;
        notchOut[i] = hp + v2;
        ubpOut[i] = k * v1;
      }
    } else if (cutoff != null && resonance == null) {
      // Constant cutoff, modulated resonance
      final resonanceBuffer = inputs[SvfFilter.resonanceInlet];
      final f = cutoff.clamp(1.0, maxCutoff);
      final g = math.tan(piOverSr * f);

      for (int i = 0; i < length; i++) {
        final q = resonanceBuffer[i].clamp(0.01, 100.0);
        final k = 1.0 / q;
        final a1 = 1.0 / (1.0 + g * (g + k));
        final a2 = g * a1;

        final v0 = inputBuffer[i];
        final v1 = a1 * s1 + a2 * (v0 - s2);
        final v2 = s2 + g * v1;

        s1 = 2.0 * v1 - s1;
        s2 = 2.0 * v2 - s2;

        final hp = v0 - k * v1 - v2;

        lpOut[i] = v2;
        bpOut[i] = v1;
        hpOut[i] = hp;
        notchOut[i] = hp + v2;
        ubpOut[i] = k * v1;
      }
    } else {
      // Both cutoff and resonance modulated per sample
      final cutoffBuffer = inputs[SvfFilter.cutoffInlet];
      final resonanceBuffer = inputs[SvfFilter.resonanceInlet];

      for (int i = 0; i < length; i++) {
        final f = cutoffBuffer[i].clamp(1.0, maxCutoff);
        final q = resonanceBuffer[i].clamp(0.01, 100.0);
        final g = math.tan(piOverSr * f);
        final k = 1.0 / q;
        final a1 = 1.0 / (1.0 + g * (g + k));
        final a2 = g * a1;

        final v0 = inputBuffer[i];
        final v1 = a1 * s1 + a2 * (v0 - s2);
        final v2 = s2 + g * v1;

        s1 = 2.0 * v1 - s1;
        s2 = 2.0 * v2 - s2;

        final hp = v0 - k * v1 - v2;

        lpOut[i] = v2;
        bpOut[i] = v1;
        hpOut[i] = hp;
        notchOut[i] = hp + v2;
        ubpOut[i] = k * v1;
      }
    }

    // Anti-denormal flushing
    if (s1.abs() < 1e-15) s1 = 0.0;
    if (s2.abs() < 1e-15) s2 = 0.0;

    _s1 = s1;
    _s2 = s2;
  }
}
