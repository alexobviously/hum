import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

List<Float32List> _inputs(
  Float32List gate, {
  Float32List? frequency,
  Float32List? feedback,
  Float32List? pickHardness,
  Float32List? pickPosition,
  Float32List? damping,
}) => [
  gate,
  frequency ?? Float32List(0),
  feedback ?? Float32List(0),
  pickHardness ?? Float32List(0),
  pickPosition ?? Float32List(0),
  damping ?? Float32List(0),
];

Float32List _renderBlocks(
  KarplusStrongProcessor proc, {
  required int sampleRate,
  required int blockSize,
  required int numBlocks,
  int gateOnSamples = 64,
  int? retriggerAtSample,
  Float32List? dampingSignal,
}) {
  final context = ProcessContext(
    sampleRate: sampleRate,
    vectorSize: blockSize,
  );
  final total = blockSize * numBlocks;
  final result = Float32List(total);

  for (int b = 0; b < numBlocks; b++) {
    final start = b * blockSize;
    final gate = Float32List(blockSize);
    Float32List? dampBlock;
    if (dampingSignal != null) {
      dampBlock = Float32List(blockSize);
    }

    for (int i = 0; i < blockSize; i++) {
      final idx = start + i;
      final firstGate = idx < gateOnSamples;
      final secondGate =
          retriggerAtSample != null &&
          idx >= retriggerAtSample &&
          idx < retriggerAtSample + gateOnSamples;
      gate[i] = (firstGate || secondGate) ? 1.0 : 0.0;
      if (dampBlock != null) {
        dampBlock[i] = dampingSignal![idx];
      }
    }

    final out = Float32List(blockSize);
    proc.process(context, _inputs(gate, damping: dampBlock), [out]);
    result.setRange(start, start + blockSize, out);
  }
  return result;
}

double _rms(Float32List samples, [int start = 0, int? end]) {
  final stop = end ?? samples.length;
  double sumSq = 0.0;
  for (int i = start; i < stop; i++) {
    final v = samples[i];
    sumSq += v * v;
  }
  return math.sqrt(sumSq / (stop - start));
}

/// Normalized high-frequency energy proxy via first-difference energy ratio.
double _hfEnergyRatio(Float32List samples, int start, int end) {
  double diffSq = 0.0;
  double energySq = 0.0;
  for (int i = start + 1; i < end; i++) {
    final d = samples[i] - samples[i - 1];
    diffSq += d * d;
    energySq += samples[i] * samples[i];
  }
  return energySq > 0.0 ? diffSq / energySq : 0.0;
}

/// Computes single-frequency DFT magnitude using a Hann window.
double _dftMagnitude(
  Float32List samples,
  int start,
  int length,
  double freq,
  int sampleRate,
) {
  double re = 0.0;
  double im = 0.0;
  final omega = (2.0 * math.pi * freq) / sampleRate;
  for (int i = 0; i < length; i++) {
    final window = 0.5 * (1.0 - math.cos((2.0 * math.pi * i) / (length - 1)));
    final x = samples[start + i] * window;
    re += x * math.cos(omega * i);
    im -= x * math.sin(omega * i);
  }
  return math.sqrt(re * re + im * im);
}

/// Estimates fundamental frequency by finding the autocorrelation peak near
/// the expected period.
double _estimatePitchHz(
  Float32List samples, {
  required int start,
  required int windowLen,
  required int sampleRate,
  required double expectedHz,
}) {
  final minLag = math.max(4, (sampleRate / (expectedHz * 1.35)).floor());
  final maxLag = math.min(
    windowLen ~/ 2,
    (sampleRate / (expectedHz * 0.65)).ceil(),
  );

  double bestCorr = double.negativeInfinity;
  int bestLag = minLag;
  final corrs = Float64List(maxLag + 2);

  for (int lag = minLag - 1; lag <= maxLag + 1; lag++) {
    double sum = 0.0;
    for (int i = 0; i < windowLen - lag; i++) {
      sum += samples[start + i] * samples[start + i + lag];
    }
    corrs[lag] = sum;
    if (lag >= minLag && lag <= maxLag && sum > bestCorr) {
      bestCorr = sum;
      bestLag = lag;
    }
  }

  // Parabolic interpolation around bestLag for sub-sample precision.
  final y0 = corrs[bestLag - 1];
  final y1 = corrs[bestLag];
  final y2 = corrs[bestLag + 1];
  final denom = y0 - 2.0 * y1 + y2;
  final shift = denom.abs() > 1e-12 ? 0.5 * (y0 - y2) / denom : 0.0;
  return sampleRate / (bestLag + shift);
}

void main() {
  group('KarplusStrong node topology & validation', () {
    test('declares expected inlets, outlets, params, and validation', () {
      final gate = Clock();
      final freqMod = SineOscillator(frequency: const .value(2.0));
      final ks = KarplusStrong(
        gate: gate.gate,
        frequency: .signal(freqMod.outlet),
        feedback: const .value(0.995),
        pickHardness: const .value(0.7),
        pickPosition: const .value(0.3),
        damping: const .value(0.4),
        interpTime: 0.03,
      );

      expect(ks.inlets.length, equals(6));
      expect(ks.inlets[KarplusStrong.gateInlet].source, equals(gate.gate));
      expect(
        ks.inlets[KarplusStrong.frequencyInlet].source,
        equals(freqMod.outlet),
      );
      expect(ks.inlets[KarplusStrong.feedbackInlet].source, isNull);
      expect(ks.inlets[KarplusStrong.pickHardnessInlet].source, isNull);
      expect(ks.inlets[KarplusStrong.pickPositionInlet].source, isNull);
      expect(ks.inlets[KarplusStrong.dampingInlet].source, isNull);

      expect(ks.outlets.length, equals(1));
      expect(ks.outlet, equals(ks.outlets.first));
      expect(ks.errors, isEmpty);

      expect(ks.params.frequency, isNull);
      expect(ks.params.feedback, equals(0.995));
      expect(ks.params.pickHardness, equals(0.7));
      expect(ks.params.pickPosition, equals(0.3));
      expect(ks.params.damping, equals(0.4));
      expect(ks.params.interpTime, equals(0.03));

      final invalid = KarplusStrong(gate: gate.gate, interpTime: -0.01);
      expect(invalid.errors, isNotEmpty);
    });

    test('supports in-place processor updates when structural props match', () {
      final gate = Clock();
      final ks1 = KarplusStrong(gate: gate.gate);
      final ks2 = KarplusStrong(
        gate: gate.gate,
        frequency: const .value(220.0),
        pickHardness: const .value(0.2),
        pickPosition: const .value(0.5),
        damping: const .value(0.8),
      );

      expect(ks1.canUpdate(ks2), isTrue);
      expect(ks1.needsUpdate(ks2), isTrue);

      final proc = ks1.createProcessor();
      proc.update(ks2.params);
      expect(proc.frequency, equals(220.0));
      expect(proc.pickHardness, equals(0.2));
      expect(proc.pickPosition, equals(0.5));
      expect(proc.damping, equals(0.8));
    });
  });

  group('KarplusStrongProcessor DSP behavior', () {
    test(
      'produces silence before gate trigger and clean pluck decay after',
      () {
        final proc = KarplusStrongProcessor(
          frequency: 220.0,
          feedback: 0.995,
          pickHardness: 0.8,
          pickPosition: 0.25,
          damping: 0.4,
        );
        final context = ProcessContext(sampleRate: 44100, vectorSize: 256);

        // Gate stays low -> strictly silent output.
        final zeroGate = Float32List(256);
        final silentOut = Float32List(256);
        proc.process(context, _inputs(zeroGate), [silentOut]);
        expect(_rms(silentOut), equals(0.0));

        // Trigger gate -> sound rings and decays over time without NaN/Inf.
        final rendered = _renderBlocks(
          proc,
          sampleRate: 44100,
          blockSize: 256,
          numBlocks: 80,
        );
        for (final s in rendered) {
          expect(s.isFinite, isTrue);
          expect(s.abs(), lessThanOrEqualTo(2.0));
        }

        final attackRms = _rms(rendered, 0, 2048);
        final tailRms = _rms(rendered, rendered.length - 2048, rendered.length);
        expect(attackRms, greaterThan(0.05));
        expect(tailRms, lessThan(attackRms));
      },
    );

    test('pickHardness shapes excitation high-frequency content', () {
      const sampleRate = 44100;
      const blockSize = 512;

      final softProc = KarplusStrongProcessor(
        frequency: 220.0,
        feedback: 0.995,
        pickHardness: 0.0,
        pickPosition: 0.25,
        damping: 0.0,
      );
      final brightProc = KarplusStrongProcessor(
        frequency: 220.0,
        feedback: 0.995,
        pickHardness: 1.0,
        pickPosition: 0.25,
        damping: 0.0,
      );

      final softAudio = _renderBlocks(
        softProc,
        sampleRate: sampleRate,
        blockSize: blockSize,
        numBlocks: 8,
      );
      final brightAudio = _renderBlocks(
        brightProc,
        sampleRate: sampleRate,
        blockSize: blockSize,
        numBlocks: 8,
      );

      final softHf = _hfEnergyRatio(softAudio, 0, 2048);
      final brightHf = _hfEnergyRatio(brightAudio, 0, 2048);

      // Soft thumb should remain clearly audible while having far less HF energy.
      expect(_rms(softAudio, 0, 2048), greaterThan(0.03));
      expect(brightHf, greaterThan(softHf * 3.0));
    });

    test('pickPosition comb-filters excitation harmonics at fractional positions', () {
      const sampleRate = 44100;
      const freq = 220.0;

      // Use zero loop damping and high feedback so initial excitation spectrum
      // is preserved into the steady-state analysis window.
      final middleProc = KarplusStrongProcessor(
        frequency: freq,
        feedback: 0.999,
        pickHardness: 1.0,
        pickPosition: 0.5,
        damping: 0.0,
      );
      final quarterProc = KarplusStrongProcessor(
        frequency: freq,
        feedback: 0.999,
        pickHardness: 1.0,
        pickPosition: 0.25,
        damping: 0.0,
      );
      final bridgeProc = KarplusStrongProcessor(
        frequency: freq,
        feedback: 0.999,
        pickHardness: 1.0,
        pickPosition: 0.1,
        damping: 0.0,
      );

      final midAudio = _renderBlocks(
        middleProc,
        sampleRate: sampleRate,
        blockSize: 512,
        numBlocks: 24,
      );
      final quarterAudio = _renderBlocks(
        quarterProc,
        sampleRate: sampleRate,
        blockSize: 512,
        numBlocks: 24,
      );
      final bridgeAudio = _renderBlocks(
        bridgeProc,
        sampleRate: sampleRate,
        blockSize: 512,
        numBlocks: 24,
      );

      const start = 2048;
      const winLen = 8192;

      // At p = 0.5, 2*f0 is cancelled relative to f0.
      final midH1 = _dftMagnitude(midAudio, start, winLen, freq, sampleRate);
      final midH2 = _dftMagnitude(
        midAudio,
        start,
        winLen,
        freq * 2,
        sampleRate,
      );
      final bridgeH1 = _dftMagnitude(
        bridgeAudio,
        start,
        winLen,
        freq,
        sampleRate,
      );
      final bridgeH2 = _dftMagnitude(
        bridgeAudio,
        start,
        winLen,
        freq * 2,
        sampleRate,
      );

      final midH2Ratio = midH2 / midH1;
      final bridgeH2Ratio = bridgeH2 / bridgeH1;
      expect(midH2Ratio, lessThan(0.15));
      expect(bridgeH2Ratio, greaterThan(midH2Ratio * 4.0));

      // At p = 0.25, 4*f0 is cancelled while 2*f0 remains present.
      final qH1 = _dftMagnitude(quarterAudio, start, winLen, freq, sampleRate);
      final qH2 = _dftMagnitude(
        quarterAudio,
        start,
        winLen,
        freq * 2,
        sampleRate,
      );
      final qH4 = _dftMagnitude(
        quarterAudio,
        start,
        winLen,
        freq * 4,
        sampleRate,
      );
      expect(qH2 / qH1, greaterThan(0.3));
      expect(qH4 / qH1, lessThan(0.15));
    });

    test('damping reduces high frequencies and engages palm-mute decay', () {
      const sampleRate = 44100;
      const blockSize = 512;

      final brightProc = KarplusStrongProcessor(
        frequency: 220.0,
        feedback: 0.997,
        pickHardness: 1.0,
        pickPosition: 0.2,
        damping: 0.0,
      );
      final warmProc = KarplusStrongProcessor(
        frequency: 220.0,
        feedback: 0.997,
        pickHardness: 1.0,
        pickPosition: 0.2,
        damping: 0.45,
      );
      final mutedProc = KarplusStrongProcessor(
        frequency: 220.0,
        feedback: 0.997,
        pickHardness: 1.0,
        pickPosition: 0.2,
        damping: 1.0,
      );

      final brightAudio = _renderBlocks(
        brightProc,
        sampleRate: sampleRate,
        blockSize: blockSize,
        numBlocks: 30,
      );
      final warmAudio = _renderBlocks(
        warmProc,
        sampleRate: sampleRate,
        blockSize: blockSize,
        numBlocks: 30,
      );
      final mutedAudio = _renderBlocks(
        mutedProc,
        sampleRate: sampleRate,
        blockSize: blockSize,
        numBlocks: 30,
      );

      // Warm damping rolls off high frequencies faster over time.
      final brightTailHf = _hfEnergyRatio(brightAudio, 4096, 12288);
      final warmTailHf = _hfEnergyRatio(warmAudio, 4096, 12288);
      expect(warmTailHf, lessThan(brightTailHf * 0.5));

      // Heavy damping (palm mute) decays overall energy dramatically faster.
      final warmTailRms = _rms(warmAudio, 10240, 14336);
      final mutedTailRms = _rms(mutedAudio, 10240, 14336);
      expect(mutedTailRms, lessThan(warmTailRms * 0.1));
    });

    test('phase-delay compensation keeps pitch accurate across damping', () {
      const sampleRate = 44100;
      const targetHz = 440.0;

      for (final d in [0.0, 0.25, 0.5, 0.75]) {
        final proc = KarplusStrongProcessor(
          frequency: targetHz,
          feedback: 0.997,
          pickHardness: 0.9,
          pickPosition: 0.2,
          damping: d,
        );
        final audio = _renderBlocks(
          proc,
          sampleRate: sampleRate,
          blockSize: 512,
          numBlocks: 24,
        );
        final estimatedHz = _estimatePitchHz(
          audio,
          start: 2048,
          windowLen: 4096,
          sampleRate: sampleRate,
          expectedHz: targetHz,
        );
        expect(
          estimatedHz,
          closeTo(targetHz, targetHz * 0.01),
          reason: 'Pitch drifted at damping=$d (estimated $estimatedHz Hz)',
        );
      }
    });

    test('damping updates glide smoothly without click discontinuities', () {
      const sampleRate = 44100;
      const blockSize = 256;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: blockSize,
      );

      double runReleaseTransition(double interpTime) {
        final proc = KarplusStrongProcessor(
          frequency: 440.0,
          feedback: 0.997,
          pickHardness: 0.9,
          pickPosition: 0.25,
          damping: 0.85,
          interpTime: interpTime,
        );

        // Pluck and let ring for 8 blocks so the wave is smooth and warm.
        final pre = _renderBlocks(
          proc,
          sampleRate: sampleRate,
          blockSize: blockSize,
          numBlocks: 8,
        );
        final prev1 = pre[pre.length - 1];
        final prev2 = pre[pre.length - 2];

        // Abruptly release damping from 0.85 down to 0.05.
        proc.update((
          frequency: 440.0,
          feedback: 0.997,
          pickHardness: 0.9,
          pickPosition: 0.25,
          damping: 0.05,
          interpTime: interpTime,
        ));

        final postGate = Float32List(blockSize);
        final postOut = Float32List(blockSize);
        proc.process(context, _inputs(postGate), [postOut]);

        // Measure discontinuity (2nd-order jump) right at the update boundary.
        return (postOut[0] - 2.0 * prev1 + prev2).abs();
      }

      final unsmoothedClick = runReleaseTransition(0.0);
      final smoothedClick = runReleaseTransition(0.02);

      expect(smoothedClick, lessThan(unsmoothedClick * 0.25));
    });

    test('supports low frequencies at high sample rates and audio-rate mod', () {
      // 25 Hz at 96 kHz requires 3840 samples (> legacy 4096 with comb/interp)
      // and 20 Hz at 96 kHz requires 4800 samples (> 4096).
      final proc = KarplusStrongProcessor(
        frequency: 20.0,
        feedback: 0.995,
        pickHardness: 0.7,
        pickPosition: 0.25,
        damping: 0.3,
      );
      final audio96k = _renderBlocks(
        proc,
        sampleRate: 96000,
        blockSize: 512,
        numBlocks: 16,
      );
      expect(_rms(audio96k, 0, 4096), greaterThan(0.02));
      for (final s in audio96k) {
        expect(s.isFinite, isTrue);
      }

      // Full AudioEngine graph integration with audio-rate parameter modulation.
      final clock = Clock(frequency: const .value(4.0));
      final lfo = SineOscillator(frequency: const .value(1.5));
      final modulatedPos = MapRange.bipolar(
        input: lfo.outlet,
        outLow: 0.1,
        outHigh: 0.5,
      );
      final ks = KarplusStrong(
        gate: clock.gate,
        frequency: const .value(220.0),
        feedback: const .value(0.995),
        pickHardness: const .value(0.8),
        pickPosition: .signal(modulatedPos.outlet),
        damping: const .value(0.35),
      );

      final context = ProcessContext(sampleRate: 44100, vectorSize: 256);
      final engine = AudioEngine(context: context);
      final snapshot = compileGraph(root: Out.mono(ks.outlet)).snapshot!;
      engine.applyDiff(diffGraph(GraphSnapshot.empty, snapshot));

      double sumSq = 0.0;
      for (int b = 0; b < 16; b++) {
        engine.process();
        final buf = engine.outputs[0];
        for (int i = 0; i < buf.length; i++) {
          sumSq += buf[i] * buf[i];
        }
      }
      expect(math.sqrt(sumSq / (16 * 256)), greaterThan(0.01));
    });
  });
}
