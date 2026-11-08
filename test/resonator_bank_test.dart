import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

List<Float32List> _resonatorInputs(Float32List inL, [Float32List? inR]) => [
  Float32List(0), // frequencyMultiplier
  Float32List(0), // q
  Float32List(0), // brightness
  Float32List(0), // spread
  Float32List(0), // mix
  inL,
  ?inR,
];

void main() {
  group('ResonatorBank topology & declarations', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final mono = ResonatorBank.mono(
        oscA.outlet,
        frequencies: [220.0, 440.0, 880.0],
      );
      expect(mono.numInputChannels, equals(1));
      // 5 control inlets + 1 audio inlet = 6 inlets
      expect(mono.inlets.length, equals(6));
      expect(
        mono.inlets[ResonatorBank.frequencyMultiplierInlet].index,
        equals(0),
      );
      expect(mono.inlets[ResonatorBank.qInlet].index, equals(1));
      expect(mono.inlets[ResonatorBank.brightnessInlet].index, equals(2));
      expect(mono.inlets[ResonatorBank.spreadInlet].index, equals(3));
      expect(mono.inlets[ResonatorBank.mixInlet].index, equals(4));
      expect(
        mono.inlets[ResonatorBank.audioInletOffset].source,
        equals(oscA.outlet),
      );

      // ResonatorBank always outputs stereo [left, right]
      expect(mono.outlets.length, equals(2));
      expect(mono.left, equals(mono.outlets[0]));
      expect(mono.right, equals(mono.outlets[1]));
      expect(mono.outlet, equals(mono.left));

      final stereo = ResonatorBank.stereo(
        oscA.outlet,
        oscB.outlet,
        frequencies: [220.0, 440.0],
      );
      expect(stereo.numInputChannels, equals(2));
      // 5 control inlets + 2 audio inlets = 7 inlets
      expect(stereo.inlets.length, equals(7));
      expect(
        stereo.inlets[ResonatorBank.audioInletOffset].source,
        equals(oscA.outlet),
      );
      expect(
        stereo.inlets[ResonatorBank.audioInletOffset + 1].source,
        equals(oscB.outlet),
      );
    });

    test('validates frequency parameters in errors list', () {
      final osc = SineOscillator(frequency: const .value(440));

      final emptyFreqs = ResonatorBank.mono(osc.outlet, frequencies: []);
      expect(emptyFreqs.errors.isNotEmpty, isTrue);

      final negativeFreqs = ResonatorBank.mono(
        osc.outlet,
        frequencies: [-100.0, 440.0],
      );
      expect(negativeFreqs.errors.isNotEmpty, isTrue);

      final valid = ResonatorBank.mono(osc.outlet, frequencies: [200.0, 400.0]);
      expect(valid.errors.isEmpty, isTrue);
    });

    test('harmonics factory creates arithmetic harmonic series', () {
      final osc = SineOscillator(frequency: const .value(100));
      final bank = ResonatorBank.harmonics(
        osc.outlet,
        fundamental: 100.0,
        count: 4,
      );

      expect(bank.frequencies.length, equals(4));
      expect(bank.frequencies[0], equals(100.0));
      expect(bank.frequencies[1], equals(200.0));
      expect(bank.frequencies[2], equals(300.0));
      expect(bank.frequencies[3], equals(400.0));
      expect(bank.gains?[0], equals(1.0));
      expect(bank.gains?[1], closeTo(0.5, 1e-4));
      expect(bank.gains?[2], closeTo(1.0 / 3.0, 1e-4));
      expect(bank.gains?[3], equals(0.25));
    });

    test('chord factory translates Note instances to frequencies', () {
      final osc = SineOscillator(frequency: const .value(440));
      final chordBank = ResonatorBank.chord(
        osc.outlet,
        notes: [Note.parse('A2'), Note.parse('E3'), Note.parse('A3')],
      );

      expect(chordBank.frequencies.length, equals(3));
      expect(chordBank.frequencies[0], closeTo(110.0, 0.1));
      expect(chordBank.frequencies[1], closeTo(164.81, 0.1));
      expect(chordBank.frequencies[2], closeTo(220.0, 0.1));
    });

    test('formant factory configures classic vowel formant frequencies', () {
      final osc = SineOscillator(frequency: const .value(100));

      final vowelA = ResonatorBank.formant(osc.outlet, vowel: .a);
      expect(vowelA.frequencies[0], equals(800.0));
      expect(vowelA.frequencies[1], equals(1200.0));
      expect(vowelA.frequencies[2], equals(2500.0));
      expect(vowelA.frequencies[3], equals(3500.0));

      final vowelI = ResonatorBank.formant(osc.outlet, vowel: .i);
      expect(vowelI.frequencies[0], equals(270.0));
      expect(vowelI.frequencies[1], equals(2290.0));
    });

    test('Outlet.resonate extension syntax builds ResonatorBank node', () {
      final osc = SineOscillator(frequency: const .value(440));
      final bank = osc.outlet.resonate(frequencies: [300.0, 600.0]);
      expect(bank, isA<ResonatorBank>());
      expect(bank.frequencies, equals([300.0, 600.0]));
    });
  });

  group('ResonatorBankProcessor audio DSP behavior', () {
    test('impulse excitation produces ringing exponential decay tail', () {
      const sampleRate = 44100;
      const vectorSize = 256;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final processor = ResonatorBankProcessor(
        numInputChannels: 1,
        frequencies: [440.0],
        gains: [1.0],
        q: 50.0,
        spread: 0.0,
      );

      // Block 1: Unit impulse at sample 0 followed by silence
      final impulseBuf = Float32List(vectorSize);
      impulseBuf[0] = 1.0;
      final outL = Float32List(vectorSize);
      final outR = Float32List(vectorSize);

      processor.process(context, _resonatorInputs(impulseBuf), [outL, outR]);

      // Output should ring across the block (theoretical peak ≈ 0.00088)
      final peakBlock1 = outL.map((s) => s.abs()).reduce(math.max);
      expect(peakBlock1, greaterThan(0.0005));
      // Should oscillate and produce both positive and negative deflections
      expect(outL.any((s) => s > 0.0002), isTrue);
      expect(outL.any((s) => s < -0.0002), isTrue);

      // Block 2: Only silence in
      final silentBuf = Float32List(vectorSize);
      final outL2 = Float32List(vectorSize);
      final outR2 = Float32List(vectorSize);

      processor.process(context, _resonatorInputs(silentBuf), [outL2, outR2]);

      // High Q means it continues to ring stably across blocks
      final peakBlock2 = outL2.map((s) => s.abs()).reduce(math.max);
      expect(peakBlock2, greaterThan(0.0001));
      // But decays exponentially (peakBlock2 < peakBlock1)
      expect(peakBlock2, lessThan(peakBlock1));
    });

    test(
      'unit-gain bandpass peak remains bounded without exploding at high Q',
      () {
        const sampleRate = 44100;
        const vectorSize = 256;
        final context = ProcessContext(
          sampleRate: sampleRate,
          vectorSize: vectorSize,
        );

        // Resonator with Q = 30.0
        final processor = ResonatorBankProcessor(
          numInputChannels: 1,
          frequencies: [440.0],
          gains: [1.0],
          q: 30.0,
          spread: 0.0,
        );

        // Continuous phase 440 Hz sine wave with amplitude 1.0
        final inBuf = Float32List(vectorSize);
        final outL = Float32List(vectorSize);
        final outR = Float32List(vectorSize);

        int sampleIndex = 0;
        var maxOut = 0.0;
        for (int b = 0; b < 30; b++) {
          for (int i = 0; i < vectorSize; i++) {
            inBuf[i] = math.sin(
              2.0 * math.pi * 440.0 * sampleIndex / sampleRate,
            );
            sampleIndex++;
          }
          processor.process(context, _resonatorInputs(inBuf), [outL, outR]);
          if (b >= 20) {
            for (int i = 0; i < vectorSize; i++) {
              if (outL[i].abs() > maxOut) maxOut = outL[i].abs();
            }
          }
        }

        // At center pan, equal-power gain is sqrt(0.5) ≈ 0.7071
        // Peak amplitude at resonance must remain bounded near 0.7071 (0 dB peak gain), NOT explode!
        expect(maxOut, closeTo(math.sqrt(0.5), 0.08));
      },
    );

    test('attenuates frequencies far away from resonant modes', () {
      const sampleRate = 44100;
      const vectorSize = 256;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Resonator tuned to 440 Hz with high Q
      final processor = ResonatorBankProcessor(
        numInputChannels: 1,
        frequencies: [440.0],
        gains: [1.0],
        q: 40.0,
        spread: 0.0,
      );

      // Input sine at 100 Hz (far away from 440 Hz) with amplitude 1.0
      final inBuf = Float32List(vectorSize);
      final outL = Float32List(vectorSize);
      final outR = Float32List(vectorSize);

      int sampleIndex = 0;
      for (int b = 0; b < 20; b++) {
        for (int i = 0; i < vectorSize; i++) {
          inBuf[i] = math.sin(2.0 * math.pi * 100.0 * sampleIndex / sampleRate);
          sampleIndex++;
        }
        processor.process(context, _resonatorInputs(inBuf), [outL, outR]);
      }

      final maxOut = outL.map((s) => s.abs()).reduce(math.max);
      // 100 Hz must be heavily attenuated compared to 1.0 input
      expect(maxOut, lessThan(0.05));
    });

    test('spread parameter controls stereo decorrelation vs mono center', () {
      const sampleRate = 44100;
      const vectorSize = 64;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      final monoProc = ResonatorBankProcessor(
        numInputChannels: 1,
        frequencies: [220.0, 440.0, 660.0],
        spread: 0.0,
      );
      final stereoProc = ResonatorBankProcessor(
        numInputChannels: 1,
        frequencies: [220.0, 440.0, 660.0],
        spread: 1.0,
      );

      final inBuf = Float32List(vectorSize);
      inBuf[0] = 1.0; // impulse

      final outMonoL = Float32List(vectorSize);
      final outMonoR = Float32List(vectorSize);
      monoProc.process(context, _resonatorInputs(inBuf), [outMonoL, outMonoR]);

      // Spread 0.0 -> left and right must be identical
      for (int i = 0; i < vectorSize; i++) {
        expect(outMonoL[i], closeTo(outMonoR[i], 1e-6));
      }

      final outStereoL = Float32List(vectorSize);
      final outStereoR = Float32List(vectorSize);
      stereoProc.process(context, _resonatorInputs(inBuf), [
        outStereoL,
        outStereoR,
      ]);

      // Spread 1.0 -> left and right must differ due to stereo panning
      bool differ = false;
      for (int i = 0; i < vectorSize; i++) {
        if ((outStereoL[i] - outStereoR[i]).abs() > 1e-4) {
          differ = true;
          break;
        }
      }
      expect(differ, isTrue);
    });

    test('frequencyMultiplier transposes resonant modes', () {
      const sampleRate = 44100;
      const vectorSize = 256;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );

      // Base frequency 220 Hz, transposed up 2x (octave up to 440 Hz)
      final processor = ResonatorBankProcessor(
        numInputChannels: 1,
        frequencies: [220.0],
        frequencyMultiplier: 2.0,
        gains: [1.0],
        q: 30.0,
        spread: 0.0,
      );

      // Excitation sine wave at 440 Hz
      final inBuf = Float32List(vectorSize);
      final outL = Float32List(vectorSize);
      final outR = Float32List(vectorSize);

      int sampleIndex = 0;
      var maxOut = 0.0;
      for (int b = 0; b < 30; b++) {
        for (int i = 0; i < vectorSize; i++) {
          inBuf[i] = math.sin(2.0 * math.pi * 440.0 * sampleIndex / sampleRate);
          sampleIndex++;
        }
        processor.process(context, _resonatorInputs(inBuf), [outL, outR]);
        if (b >= 20) {
          for (int i = 0; i < vectorSize; i++) {
            if (outL[i].abs() > maxOut) maxOut = outL[i].abs();
          }
        }
      }

      // Since frequency was transposed to 440 Hz, it resonates strongly at 440 Hz (near sqrt(0.5) ≈ 0.7071)
      expect(maxOut, closeTo(math.sqrt(0.5), 0.08));
    });
  });

  group('ResonatorBank in AudioPipeline', () {
    test('compiles and executes inside AudioPipeline with live updates', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final noise = NoiseGenerator(type: .pink);
      final bank = ResonatorBank.harmonics(
        noise.outlet,
        fundamental: 110.0,
        count: 5,
        q: const .value(30.0),
      );

      final pipeline = compilePipeline(root: bank, context: context).pipeline!;
      pipeline.process();
      final outL = pipeline.outputs[0];
      final outR = pipeline.outputs[1];

      expect(outL.any((s) => s != 0.0), isTrue);
      expect(outR.any((s) => s != 0.0), isTrue);
      expect(outL.every((s) => s.isFinite), isTrue);

      // Live update
      final updated = ResonatorBank.harmonics(
        noise.outlet,
        fundamental: 220.0,
        count: 5,
        q: const .value(50.0),
      );
      pipeline.update(bank, updated);
      pipeline.process();

      expect(pipeline.outputs[0].any((s) => s != 0.0), isTrue);
    });

    test('modulates frequencyMultiplier dynamically via audio-rate signal', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final noise = NoiseGenerator(type: .pink);
      final lfo = SineOscillator(frequency: const .value(5)).mapRange(0.8, 1.2);

      final bank = ResonatorBank.formant(
        noise.outlet,
        vowel: .a,
        frequencyMultiplier: ControlParam.signal(lfo.outlet),
      );

      final pipeline = compilePipeline(root: bank, context: context).pipeline!;
      for (int b = 0; b < 5; b++) {
        pipeline.process();
      }

      final outL = pipeline.outputs[0];
      expect(outL.any((s) => s != 0.0), isTrue);
      expect(outL.every((s) => s.isFinite), isTrue);
    });
  });
}
