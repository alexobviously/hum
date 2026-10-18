import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('SvfFilter node', () {
    test('declares expected inlets and outlets', () {
      final osc = SineOscillator(frequency: .value(440));
      final svf = SvfFilter(
        input: osc.outlet,
        cutoff: .value(1000),
        resonance: .value(2.0),
      );

      expect(svf.inlets.length, equals(3));
      expect(svf.inlets[SvfFilter.inputInlet].source, equals(osc.outlet));
      expect(svf.inlets[SvfFilter.cutoffInlet].source, isNull);
      expect(svf.inlets[SvfFilter.resonanceInlet].source, isNull);

      expect(svf.outlets.length, equals(5));
      expect(svf.outlet, equals(svf.lowpass));
      expect(svf.lowpass.index, equals(SvfFilter.lowpassOutlet));
      expect(svf.bandpass.index, equals(SvfFilter.bandpassOutlet));
      expect(svf.highpass.index, equals(SvfFilter.highpassOutlet));
      expect(svf.notch.index, equals(SvfFilter.notchOutlet));
      expect(svf.unitBandpass.index, equals(SvfFilter.unitBandpassOutlet));

      expect(svf.params.cutoff, equals(1000.0));
      expect(svf.params.resonance, equals(2.0));
    });

    test('supports signal inlets for cutoff and resonance', () {
      final osc = SineOscillator(frequency: .value(440));
      final lfoCutoff = SineOscillator(frequency: .value(2));
      final lfoRes = SineOscillator(frequency: .value(1));

      final svf = SvfFilter(
        input: osc.outlet,
        cutoff: .signal(lfoCutoff.outlet),
        resonance: .signal(lfoRes.outlet),
      );

      expect(
        svf.inlets[SvfFilter.cutoffInlet].source,
        equals(lfoCutoff.outlet),
      );
      expect(
        svf.inlets[SvfFilter.resonanceInlet].source,
        equals(lfoRes.outlet),
      );
      expect(svf.params.cutoff, isNull);
      expect(svf.params.resonance, isNull);
    });
  });

  group('SvfFilterProcessor frequency response', () {
    test('exhibits correct DC behavior for all outputs', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final processor = SvfFilterProcessor(cutoff: 1000, resonance: 0.7071);

      final inBuffer = Float32List(64);
      final lpOut = Float32List(64);
      final bpOut = Float32List(64);
      final hpOut = Float32List(64);
      final notchOut = Float32List(64);
      final ubpOut = Float32List(64);

      // Unit step (DC = 1.0) for several blocks to settle
      for (int i = 0; i < 64; i++) {
        inBuffer[i] = 1.0;
      }

      for (int block = 0; block < 20; block++) {
        processor.process(
          context,
          [inBuffer, Float32List(64), Float32List(64)],
          [lpOut, bpOut, hpOut, notchOut, ubpOut],
        );
      }

      // At DC steady state:
      // Lowpass = 1.0 (unity gain)
      expect(lpOut.last, closeTo(1.0, 1e-4));
      // Highpass = 0.0 (blocks DC)
      expect(hpOut.last, closeTo(0.0, 1e-4));
      // Bandpass = 0.0 (blocks DC)
      expect(bpOut.last, closeTo(0.0, 1e-4));
      expect(ubpOut.last, closeTo(0.0, 1e-4));
      // Notch = 1.0 (passes DC)
      expect(notchOut.last, closeTo(1.0, 1e-4));
    });

    test('exhibits correct Nyquist behavior for lowpass and highpass', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final processor = SvfFilterProcessor(cutoff: 1000, resonance: 0.7071);

      final inBuffer = Float32List(64);
      final lpOut = Float32List(64);
      final bpOut = Float32List(64);
      final hpOut = Float32List(64);
      final notchOut = Float32List(64);
      final ubpOut = Float32List(64);

      // Alternating +1, -1 at Nyquist
      for (int i = 0; i < 64; i++) {
        inBuffer[i] = (i % 2 == 0) ? 1.0 : -1.0;
      }

      for (int block = 0; block < 20; block++) {
        processor.process(
          context,
          [inBuffer, Float32List(64), Float32List(64)],
          [lpOut, bpOut, hpOut, notchOut, ubpOut],
        );
      }

      // At Nyquist:
      // Lowpass strongly attenuates high frequencies
      expect(lpOut.last.abs(), lessThan(0.01));
      // Highpass passes Nyquist at unity gain
      expect(hpOut.last.abs(), closeTo(1.0, 1e-2));
    });

    test('amplifies resonant peak according to Q', () {
      const sampleRate = 44100;
      const cutoff = 1000.0;
      const q = 5.0;

      final context = ProcessContext(sampleRate: sampleRate, vectorSize: 64);
      final processor = SvfFilterProcessor(cutoff: cutoff, resonance: q);

      final inBuffer = Float32List(64);
      final lpOut = Float32List(64);
      final bpOut = Float32List(64);
      final hpOut = Float32List(64);
      final notchOut = Float32List(64);
      final ubpOut = Float32List(64);

      var maxLp = 0.0;
      var maxUbp = 0.0;

      int sampleIndex = 0;
      for (int block = 0; block < 40; block++) {
        for (int i = 0; i < 64; i++) {
          inBuffer[i] = math.sin(
            2 * math.pi * cutoff * sampleIndex / sampleRate,
          );
          sampleIndex++;
        }

        processor.process(
          context,
          [inBuffer, Float32List(64), Float32List(64)],
          [lpOut, bpOut, hpOut, notchOut, ubpOut],
        );

        if (block > 20) {
          for (int i = 0; i < 64; i++) {
            if (lpOut[i].abs() > maxLp) maxLp = lpOut[i].abs();
            if (ubpOut[i].abs() > maxUbp) maxUbp = ubpOut[i].abs();
          }
        }
      }

      // Resonant lowpass peaks close to Q (5.0) at the cutoff frequency
      expect(maxLp, closeTo(q, 0.2));
      // Unit-gain bandpass peak remains close to 1.0 (0 dB) regardless of Q
      expect(maxUbp, closeTo(1.0, 0.1));
    });

    test('remains stable under audio-rate cutoff modulation', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final processor = SvfFilterProcessor(cutoff: null, resonance: 4.0);

      final inBuffer = Float32List(64);
      final cutoffBuffer = Float32List(64);
      final lpOut = Float32List(64);
      final bpOut = Float32List(64);
      final hpOut = Float32List(64);
      final notchOut = Float32List(64);
      final ubpOut = Float32List(64);

      for (int i = 0; i < 64; i++) {
        inBuffer[i] = 1.0;
      }

      // Modulate cutoff violently between 100 Hz and 15,000 Hz
      for (int block = 0; block < 50; block++) {
        for (int i = 0; i < 64; i++) {
          cutoffBuffer[i] = 100.0 + 14000.0 * (0.5 + 0.5 * math.sin(block + i));
        }

        processor.process(
          context,
          [inBuffer, cutoffBuffer, Float32List(64)],
          [lpOut, bpOut, hpOut, notchOut, ubpOut],
        );

        expect(lpOut.every((s) => s.isFinite), isTrue);
        expect(hpOut.every((s) => s.isFinite), isTrue);
        expect(bpOut.every((s) => s.isFinite), isTrue);
      }
    });

    test('update method updates live parameters', () {
      final processor = SvfFilterProcessor(cutoff: 500, resonance: 1.0);
      expect(processor.cutoff, equals(500));
      expect(processor.resonance, equals(1.0));

      processor.update((cutoff: 2000.0, resonance: 4.0));
      expect(processor.cutoff, equals(2000.0));
      expect(processor.resonance, equals(4.0));
    });
  });

  group('SvfFilter in compiled pipeline', () {
    test('renders lowpass and bandpass in graph pipeline', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final noise = NoiseGenerator.white(seed: 1234);
      final svf = SvfFilter(
        input: noise.outlet,
        cutoff: .value(800),
        resonance: .value(2.0),
      );

      final pipeline = compilePipeline(
        roots: [svf],
        targetOutputs: [svf.lowpass, svf.bandpass],
        context: context,
      );

      expect(pipeline.outputs.length, equals(2));
      pipeline.process();

      final lp = pipeline.outputs[0];
      final bp = pipeline.outputs[1];

      expect(lp.length, equals(64));
      expect(bp.length, equals(64));
      expect(lp.any((s) => s != 0.0), isTrue);
      expect(bp.any((s) => s != 0.0), isTrue);
    });
  });
}
