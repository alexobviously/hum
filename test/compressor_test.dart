import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

List<Float32List> _compressorInputs(Float32List inL, [Float32List? inR]) => [
  Float32List(0), // threshold
  Float32List(0), // ratio
  Float32List(0), // attack
  Float32List(0), // release
  Float32List(0), // knee
  Float32List(0), // makeupGain
  Float32List(0), // sidechain
  inL,
  ?inR,
];

void main() {
  group('Compressor node topology & declarations', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final mono = Compressor.mono(oscA.outlet);
      expect(mono.numChannels, equals(1));
      expect(mono.inlets.length, equals(8)); // 6 params + sidechain + 1 audio
      expect(
        mono.inlets[Compressor.thresholdInlet].index,
        equals(Compressor.thresholdInlet),
      );
      expect(
        mono.inlets[Compressor.ratioInlet].index,
        equals(Compressor.ratioInlet),
      );
      expect(
        mono.inlets[Compressor.attackInlet].index,
        equals(Compressor.attackInlet),
      );
      expect(
        mono.inlets[Compressor.releaseInlet].index,
        equals(Compressor.releaseInlet),
      );
      expect(
        mono.inlets[Compressor.kneeInlet].index,
        equals(Compressor.kneeInlet),
      );
      expect(
        mono.inlets[Compressor.makeupGainInlet].index,
        equals(Compressor.makeupGainInlet),
      );
      expect(
        mono.inlets[Compressor.sidechainInlet].index,
        equals(Compressor.sidechainInlet),
      );
      expect(
        mono.inlets[Compressor.audioInletOffset].source,
        equals(oscA.outlet),
      );
      expect(mono.outlets.length, equals(1));
      expect(mono.outlet, equals(mono.outlets.first));

      final stereo = Compressor.stereo(oscA.outlet, oscB.outlet);
      expect(stereo.numChannels, equals(2));
      expect(stereo.inlets.length, equals(9)); // 6 params + sidechain + 2 audio
      expect(stereo.outlets.length, equals(2));
      expect(stereo.left, equals(stereo.outlets[0]));
      expect(stereo.right, equals(stereo.outlets[1]));
    });

    test(
      'limiter preset configures infinite ratio and brickwall parameters',
      () {
        final osc = SineOscillator(frequency: const .value(440));
        final limiter = Compressor.limiter([osc.outlet]);

        expect(limiter.numChannels, equals(1));
        expect(limiter.ratio.valueOrNull, equals(double.infinity));
        expect(limiter.threshold.valueOrNull, equals(-0.5));
        expect(limiter.attack.valueOrNull, equals(0.001));
        expect(limiter.release.valueOrNull, equals(0.050));
        expect(limiter.knee.valueOrNull, equals(0.0));
      },
    );

    test('validates parameter constraints in errors list', () {
      final osc = SineOscillator(frequency: const .value(440));

      final valid = Compressor.mono(osc.outlet);
      expect(valid.errors, isEmpty);

      final emptyChannels = Compressor(channels: const []);
      expect(emptyChannels.errors, isNotEmpty);

      final invalidRatio = Compressor(
        channels: [osc.outlet],
        ratio: const .value(0.5),
      );
      expect(invalidRatio.errors, isNotEmpty);

      final invalidAttack = Compressor(
        channels: [osc.outlet],
        attack: const .value(-0.01),
      );
      expect(invalidAttack.errors, isNotEmpty);

      final invalidRelease = Compressor(
        channels: [osc.outlet],
        release: const .value(-0.1),
      );
      expect(invalidRelease.errors, isNotEmpty);

      final invalidKnee = Compressor(
        channels: [osc.outlet],
        knee: const .value(-1.0),
      );
      expect(invalidKnee.errors, isNotEmpty);
    });

    test('canUpdate handles matching channels and sidechain presence', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final compMono1 = Compressor.mono(oscA.outlet);
      final compMono2 = Compressor.mono(
        oscA.outlet,
        threshold: const .value(-12.0),
      );
      final compStereo = Compressor.stereo(oscA.outlet, oscB.outlet);
      final compSidechain = Compressor.mono(
        oscA.outlet,
        sidechain: oscB.outlet,
      );

      expect(compMono1.canUpdate(compMono2), isTrue);
      expect(compMono1.canUpdate(compStereo), isFalse);
      expect(compMono1.canUpdate(compSidechain), isFalse);
    });

    test('OutletCompressorExtension creates mono compressor and limiter', () {
      final osc = SineOscillator(frequency: const .value(440));
      final comp = osc.outlet.compress(threshold: const .value(-12.0));
      expect(comp.numChannels, equals(1));
      expect(comp.threshold.valueOrNull, equals(-12.0));

      final lim = osc.outlet.limit(threshold: const .value(-1.0));
      expect(lim.numChannels, equals(1));
      expect(lim.ratio.valueOrNull, equals(double.infinity));
      expect(lim.threshold.valueOrNull, equals(-1.0));
    });
  });

  group('CompressorProcessor static transfer characteristic', () {
    test('passes signals below threshold uncompressed (unity gain)', () {
      final processor = CompressorProcessor(
        numChannels: 1,
        threshold: -12.0,
        ratio: 4.0,
        attack: 0.0,
        release: 0.0,
        knee: 0.0,
      );

      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      // -18 dB is ~0.1259 amplitude (below -12 dB threshold)
      final inAmp = dbToGain(-18.0);
      final inBuffer = Float32List(vectorSize)..fillRange(0, vectorSize, inAmp);
      final outBuffer = Float32List(vectorSize);

      processor.process(context, _compressorInputs(inBuffer), [outBuffer]);

      for (int i = 0; i < vectorSize; i++) {
        expect(outBuffer[i], closeTo(inAmp, 1e-5));
      }
      expect(processor.gainReductionDb, closeTo(0.0, 1e-4));
    });

    test('compresses signals above threshold with 4:1 ratio', () {
      final processor = CompressorProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 4.0,
        attack: 0.0,
        release: 0.0,
        knee: 0.0,
      );

      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      // Input at 0 dB (amplitude 1.0)
      // Overshoot = 0 - (-20) = +20 dB
      // Reduction = -20 * (1 - 1/4) = -15 dB
      // Output in dB = 0 - 15 = -20 + (20 / 4) = -15 dB
      final inBuffer = Float32List(vectorSize)..fillRange(0, vectorSize, 1.0);
      final outBuffer = Float32List(vectorSize);

      processor.process(context, _compressorInputs(inBuffer), [outBuffer]);

      final expectedGain = dbToGain(-15.0);
      for (int i = 0; i < vectorSize; i++) {
        expect(outBuffer[i], closeTo(expectedGain, 1e-4));
      }
      expect(processor.gainReductionDb, closeTo(15.0, 1e-3));
    });

    test('brickwall limiter clamps all peaks strictly at threshold', () {
      final processor = CompressorProcessor(
        numChannels: 1,
        threshold: -6.0,
        ratio: double.infinity,
        attack: 0.0,
        release: 0.0,
        knee: 0.0,
      );

      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      // Amplitude 1.0 (0 dB) -> exceeds -6 dB threshold
      final inBuffer = Float32List(vectorSize)..fillRange(0, vectorSize, 1.0);
      final outBuffer = Float32List(vectorSize);

      processor.process(context, _compressorInputs(inBuffer), [outBuffer]);

      final expectedCeiling = dbToGain(-6.0);
      for (int i = 0; i < vectorSize; i++) {
        expect(outBuffer[i], closeTo(expectedCeiling, 1e-4));
      }
      expect(processor.gainReductionDb, closeTo(6.0, 1e-3));
    });

    test('smooth quadratic knee transitions gently around threshold', () {
      // Threshold: -20 dB, Ratio: 4:1, Knee: 6 dB (knee region: -23 dB to -17 dB)
      final softComp = CompressorProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 4.0,
        attack: 0.0,
        release: 0.0,
        knee: 6.0,
      );
      final hardComp = CompressorProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 4.0,
        attack: 0.0,
        release: 0.0,
        knee: 0.0,
      );

      const vectorSize = 1;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      final inBuf = Float32List(1);
      final outBuf = Float32List(1);

      // Case A: At -22 dB (inside knee, 2 dB below threshold)
      inBuf[0] = dbToGain(-22.0);
      hardComp.process(context, _compressorInputs(inBuf), [outBuf]);
      final hardReductionA = hardComp.gainReductionDb;

      softComp.process(context, _compressorInputs(inBuf), [outBuf]);
      final softReductionA = softComp.gainReductionDb;

      // Hard knee does nothing below threshold
      expect(hardReductionA, equals(0.0));
      // Soft knee has already gently started reducing
      expect(softReductionA, greaterThan(0.0));
      expect(softReductionA, lessThan(0.2));

      // Case B: Exactly at threshold (-20 dB)
      inBuf[0] = dbToGain(-20.0);
      hardComp.process(context, _compressorInputs(inBuf), [outBuf]);
      final hardReductionB = hardComp.gainReductionDb;

      softComp.process(context, _compressorInputs(inBuf), [outBuf]);
      final softReductionB = softComp.gainReductionDb;

      expect(hardReductionB, equals(0.0));
      // At threshold, soft knee reduction is (slope * (W/2)^2) / (2W) = (0.75 * 9) / 12 = 0.5625 dB
      expect(softReductionB, closeTo(0.5625, 1e-3));

      // Case C: At -17 dB (top of knee, +3 dB above threshold)
      inBuf[0] = dbToGain(-17.0);
      hardComp.process(context, _compressorInputs(inBuf), [outBuf]);
      final hardReductionC = hardComp.gainReductionDb;

      softComp.process(context, _compressorInputs(inBuf), [outBuf]);
      final softReductionC = softComp.gainReductionDb;

      // At top of knee, soft knee curve precisely meets hard knee linear reduction
      // Overshoot = +3 dB. Reduction = 3 * (1 - 1/4) = 2.25 dB
      expect(hardReductionC, closeTo(2.25, 1e-3));
      expect(softReductionC, closeTo(2.25, 1e-3));
    });

    test('makeup gain amplifies output signal linearly', () {
      final processor = CompressorProcessor(
        numChannels: 1,
        threshold: -12.0,
        ratio: 4.0,
        attack: 0.0,
        release: 0.0,
        knee: 0.0,
        makeupGain: 6.0205999, // +6 dB = factor of 2.0
      );

      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      // -18 dB input -> passes compressor with 0 dB reduction, then boosted by +6 dB
      final inAmp = dbToGain(-18.0);
      final inBuffer = Float32List(vectorSize)..fillRange(0, vectorSize, inAmp);
      final outBuffer = Float32List(vectorSize);

      processor.process(context, _compressorInputs(inBuffer), [outBuffer]);

      for (int i = 0; i < vectorSize; i++) {
        expect(outBuffer[i], closeTo(inAmp * 2.0, 1e-4));
      }
    });
  });

  group('Compressor dynamic ballistics (Attack & Release)', () {
    test('smooths gain reduction according to attack time constant', () {
      const sampleRate = 44100;
      const attackSeconds = 0.010; // 10 ms = 441 samples
      final processor = CompressorProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 4.0,
        attack: attackSeconds,
        release: 0.100,
        knee: 0.0,
      );

      const vectorSize = 441;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );
      final inBuffer = Float32List(vectorSize)
        ..fillRange(0, vectorSize, 1.0); // 0 dB
      final outBuffer = Float32List(vectorSize);

      // Target reduction is 15 dB
      processor.process(context, _compressorInputs(inBuffer), [outBuffer]);

      // At sample 0, gain reduction just started (low reduction)
      expect(outBuffer[0], closeTo(1.0, 0.05));

      // After 1 time constant (441 samples), reduction should reach ~63.2% of 15 dB = ~9.48 dB
      expect(
        processor.gainReductionDb,
        closeTo(15.0 * (1.0 - 1.0 / 2.71828), 0.5),
      );
    });

    test('recovers smoothly to unity according to release time constant', () {
      const sampleRate = 44100;
      const releaseSeconds = 0.020; // 20 ms
      final processor = CompressorProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 4.0,
        attack: 0.0, // instant attack
        release: releaseSeconds,
        knee: 0.0,
      );

      const vectorSize = 256;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );
      final loudBuffer = Float32List(vectorSize)..fillRange(0, vectorSize, 1.0);
      final silentBuffer = Float32List(vectorSize);
      final outBuffer = Float32List(vectorSize);

      // Block 1: Attack and settle at full 15 dB reduction
      processor.process(context, _compressorInputs(loudBuffer), [outBuffer]);
      expect(processor.gainReductionDb, closeTo(15.0, 1e-2));

      // Block 2: Silence arrives, release phase begins
      processor.process(context, _compressorInputs(silentBuffer), [outBuffer]);

      // Gain reduction should decay towards 0 dB
      expect(processor.gainReductionDb, lessThan(15.0));
      expect(processor.gainReductionDb, greaterThan(0.0));
    });
  });

  group('Compressor stereo linking and sidechain', () {
    test('stereo linking detects peak across channels and preserves stereo balance', () {
      final processor = CompressorProcessor(
        numChannels: 2,
        threshold: -20.0,
        ratio: 4.0,
        attack: 0.0,
        release: 0.0,
        knee: 0.0,
      );

      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      // Left channel is loud (1.0 = 0 dB), Right channel is quieter (0.2 = -14 dB)
      final leftIn = Float32List(vectorSize)..fillRange(0, vectorSize, 1.0);
      final rightIn = Float32List(vectorSize)..fillRange(0, vectorSize, 0.2);
      final leftOut = Float32List(vectorSize);
      final rightOut = Float32List(vectorSize);

      processor.process(
        context,
        _compressorInputs(leftIn, rightIn),
        [leftOut, rightOut],
      );

      // Both channels should be scaled by the exact same gain factor corresponding to 0 dB peak (-15 dB reduction)
      final expectedGain = dbToGain(-15.0);
      for (int i = 0; i < vectorSize; i++) {
        expect(leftOut[i], closeTo(1.0 * expectedGain, 1e-4));
        expect(rightOut[i], closeTo(0.2 * expectedGain, 1e-4));
      }
    });

    test('sidechain ducks audio channels based on external key signal', () {
      final audioOsc = SineOscillator(frequency: const .value(440));
      final kickOsc = SineOscillator(frequency: const .value(60));

      final comp = Compressor.mono(
        audioOsc.outlet,
        sidechain: kickOsc.outlet,
        threshold: const .value(-20.0),
        ratio: const .value(4.0),
        attack: const .value(0.0),
        release: const .value(0.0),
        knee: const .value(0.0),
      );

      final out = Out.mono(comp.outlet);
      const vectorSize = 16;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      final pipeline = compilePipeline(root: out, context: context).pipeline!;

      // Execute pipeline
      pipeline.process();

      final compProc = pipeline.processorOf(comp);
      // Sidechain is driven by kick oscillator
      expect(compProc.gainReductionDb, greaterThan(0.0));
    });
  });

  group('Compressor in AudioPipeline', () {
    test(
      'renders through compiled audio pipeline and supports live updates',
      () {
        final osc = SineOscillator(frequency: const .value(440));
        final comp = Compressor.mono(
          osc.outlet,
          threshold: const .value(-12.0),
          ratio: const .value(4.0),
        );
        final out = Out.mono(comp.outlet);

        const vectorSize = 32;
        final context = ProcessContext(
          sampleRate: 44100,
          vectorSize: vectorSize,
        );
        final result = compilePipeline(root: out, context: context);
        expect(result.hasErrors, isFalse);
        final pipeline = result.pipeline!;

        pipeline.process();
        expect(pipeline.outputs.length, equals(1));
        expect(pipeline.outputs[0].length, equals(vectorSize));

        final proc = pipeline.processorOf(comp);
        expect(proc.threshold, equals(-12.0));
        expect(proc.ratio, equals(4.0));

        // Update parameter live
        proc.update((
          threshold: -6.0,
          ratio: 8.0,
          attack: null,
          release: null,
          knee: null,
          makeupGain: null,
          hasSidechain: false,
        ));
        expect(proc.threshold, equals(-6.0));
        expect(proc.ratio, equals(8.0));
      },
    );
  });
}
