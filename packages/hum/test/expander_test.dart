import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

List<Float32List> _expanderInputs(
  Float32List inL, {
  Float32List? inR,
  Float32List? sidechain,
}) => [
  Float32List(0), // threshold
  Float32List(0), // ratio
  Float32List(0), // range
  Float32List(0), // attack
  Float32List(0), // hold
  Float32List(0), // release
  Float32List(0), // knee
  Float32List(0), // hysteresis
  sidechain ?? Float32List(0), // sidechain
  inL,
  ?inR,
];

void main() {
  group('Expander & NoiseGate node topology & declarations', () {
    test(
      'Expander declares expected inlets and outlets for mono and stereo',
      () {
        final oscA = SineOscillator(frequency: const .value(440));
        final oscB = SineOscillator(frequency: const .value(880));

        final mono = Expander.mono(oscA.outlet);
        expect(mono.numChannels, equals(1));
        expect(
          mono.inlets.length,
          equals(10),
        ); // 8 params + sidechain + 1 audio
        expect(
          mono.inlets[Expander.thresholdInlet].index,
          equals(Expander.thresholdInlet),
        );
        expect(
          mono.inlets[Expander.ratioInlet].index,
          equals(Expander.ratioInlet),
        );
        expect(
          mono.inlets[Expander.rangeInlet].index,
          equals(Expander.rangeInlet),
        );
        expect(
          mono.inlets[Expander.attackInlet].index,
          equals(Expander.attackInlet),
        );
        expect(
          mono.inlets[Expander.holdInlet].index,
          equals(Expander.holdInlet),
        );
        expect(
          mono.inlets[Expander.releaseInlet].index,
          equals(Expander.releaseInlet),
        );
        expect(
          mono.inlets[Expander.kneeInlet].index,
          equals(Expander.kneeInlet),
        );
        expect(
          mono.inlets[Expander.hysteresisInlet].index,
          equals(Expander.hysteresisInlet),
        );
        expect(
          mono.inlets[Expander.sidechainInlet].index,
          equals(Expander.sidechainInlet),
        );
        expect(
          mono.inlets[Expander.audioInletOffset].source,
          equals(oscA.outlet),
        );
        expect(mono.outlets.length, equals(1));
        expect(mono.outlet, equals(mono.outlets.first));

        final stereo = Expander.stereo(oscA.outlet, oscB.outlet);
        expect(stereo.numChannels, equals(2));
        expect(stereo.inlets.length, equals(11));
        expect(stereo.outlets.length, equals(2));
        expect(stereo.left, equals(stereo.outlets[0]));
        expect(stereo.right, equals(stereo.outlets[1]));
      },
    );

    test(
      'NoiseGate creates ExpanderProcessor with infinite ratio & hard knee',
      () {
        final osc = SineOscillator(frequency: const .value(440));
        final gate = NoiseGate.mono(osc.outlet);

        expect(gate.numChannels, equals(1));
        expect(gate.inlets.length, equals(10));
        expect(gate.outlets.length, equals(1));

        final proc = gate.createProcessor();
        expect(proc.ratio, equals(double.infinity));
        expect(proc.knee, equals(0.0));
        expect(proc.threshold, equals(-40.0));
        expect(proc.hysteresis, equals(4.0));
        expect(proc.range, equals(-80.0));
        expect(proc.hold, equals(0.050));
      },
    );

    test('validates parameter constraints in errors list', () {
      final osc = SineOscillator(frequency: const .value(440));

      expect(Expander.mono(osc.outlet).errors, isEmpty);
      expect(NoiseGate.mono(osc.outlet).errors, isEmpty);

      expect(Expander(channels: const []).errors, isNotEmpty);
      expect(NoiseGate(channels: const []).errors, isNotEmpty);

      expect(
        Expander.mono(osc.outlet, ratio: const .value(0.5)).errors,
        isNotEmpty,
      );
      expect(
        Expander.mono(osc.outlet, range: const .value(3.0)).errors,
        isNotEmpty,
      );
      expect(
        Expander.mono(osc.outlet, attack: const .value(-0.01)).errors,
        isNotEmpty,
      );
      expect(
        Expander.mono(osc.outlet, hold: const .value(-0.01)).errors,
        isNotEmpty,
      );
      expect(
        Expander.mono(osc.outlet, release: const .value(-0.1)).errors,
        isNotEmpty,
      );
      expect(
        Expander.mono(osc.outlet, knee: const .value(-1.0)).errors,
        isNotEmpty,
      );
      expect(
        Expander.mono(osc.outlet, hysteresis: const .value(-1.0)).errors,
        isNotEmpty,
      );
      expect(
        NoiseGate.mono(osc.outlet, hysteresis: const .value(-2.0)).errors,
        isNotEmpty,
      );
      expect(
        NoiseGate.mono(osc.outlet, range: const .value(1.0)).errors,
        isNotEmpty,
      );
    });

    test('canUpdate handles matching channels and sidechain presence', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final exp1 = Expander.mono(oscA.outlet);
      final exp2 = Expander.mono(oscA.outlet, threshold: const .value(-30.0));
      final expStereo = Expander.stereo(oscA.outlet, oscB.outlet);
      final expSidechain = Expander.mono(oscA.outlet, sidechain: oscB.outlet);
      final gate1 = NoiseGate.mono(oscA.outlet);
      final gate2 = NoiseGate.mono(oscA.outlet, threshold: const .value(-30.0));

      expect(exp1.canUpdate(exp2), isTrue);
      expect(exp1.canUpdate(expStereo), isFalse);
      expect(exp1.canUpdate(expSidechain), isFalse);
      expect(gate1.canUpdate(gate2), isTrue);
      expect(exp1.canUpdate(gate1), isFalse);
    });

    test('OutletExpanderExtension creates mono expander and noise gate', () {
      final osc = SineOscillator(frequency: const .value(440));
      final exp = osc.outlet.expand(threshold: const .value(-30.0));
      expect(exp.numChannels, equals(1));
      expect(exp.threshold.valueOrNull, equals(-30.0));

      final gate = osc.outlet.gate(threshold: const .value(-45.0));
      expect(gate.numChannels, equals(1));
      expect(gate.threshold.valueOrNull, equals(-45.0));
    });
  });

  group('ExpanderProcessor static transfer characteristic', () {
    test('passes signals above threshold unattenuated (unity gain)', () {
      final processor = ExpanderProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 2.0,
        range: -60.0,
        attack: 0.0,
        hold: 0.0,
        release: 0.0,
        knee: 0.0,
        hysteresis: 0.0,
      );

      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      final inAmp = dbToGain(-12.0); // above -20 dB threshold
      final inBuffer = Float32List(vectorSize)..fillRange(0, vectorSize, inAmp);
      final outBuffer = Float32List(vectorSize);

      processor.process(context, _expanderInputs(inBuffer), [outBuffer]);

      for (int i = 0; i < vectorSize; i++) {
        expect(outBuffer[i], closeTo(inAmp, 1e-5));
      }
      expect(processor.gainReductionDb, closeTo(0.0, 1e-4));
      expect(processor.isOpen, isTrue);
    });

    test('expands signals below threshold with 2:1 ratio', () {
      final processor = ExpanderProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 2.0,
        range: -60.0,
        attack: 0.0,
        hold: 0.0,
        release: 0.0,
        knee: 0.0,
        hysteresis: 0.0,
      );

      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      // Input at -30 dB -> 10 dB below threshold
      // 2:1 downward expansion -> additional -10 dB attenuation -> output at -40 dB
      final inAmp = dbToGain(-30.0);
      final inBuffer = Float32List(vectorSize)..fillRange(0, vectorSize, inAmp);
      final outBuffer = Float32List(vectorSize);

      processor.process(context, _expanderInputs(inBuffer), [outBuffer]);

      final expectedOut = dbToGain(-40.0);
      for (int i = 0; i < vectorSize; i++) {
        expect(outBuffer[i], closeTo(expectedOut, 1e-4));
      }
      expect(processor.gainReductionDb, closeTo(10.0, 1e-2));
      expect(processor.isOpen, isFalse);
    });

    test('clamps attenuation at range floor', () {
      final processor = ExpanderProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 4.0,
        range: -12.0,
        attack: 0.0,
        hold: 0.0,
        release: 0.0,
        knee: 0.0,
        hysteresis: 0.0,
      );

      const vectorSize = 8;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      // Input at -40 dB (20 dB below threshold) -> unclamped would be -60 dB, clamped to -12 dB
      final inAmp = dbToGain(-40.0);
      final inBuffer = Float32List(vectorSize)..fillRange(0, vectorSize, inAmp);
      final outBuffer = Float32List(vectorSize);

      processor.process(context, _expanderInputs(inBuffer), [outBuffer]);

      final expectedOut = dbToGain(-52.0);
      for (int i = 0; i < vectorSize; i++) {
        expect(outBuffer[i], closeTo(expectedOut, 1e-5));
      }
      expect(processor.gainReductionDb, closeTo(12.0, 1e-2));
    });

    test(
      'full mute with negativeInfinity range outputs exact zero without NaN',
      () {
        final processor = ExpanderProcessor(
          numChannels: 1,
          threshold: -20.0,
          ratio: double.infinity,
          range: double.negativeInfinity,
          attack: 0.0,
          hold: 0.0,
          release: 0.0,
          knee: 0.0,
          hysteresis: 0.0,
        );

        const vectorSize = 8;
        final context = ProcessContext(
          sampleRate: 44100,
          vectorSize: vectorSize,
        );
        final quietBuf = Float32List(vectorSize)
          ..fillRange(0, vectorSize, dbToGain(-30.0));
        final loudBuf = Float32List(vectorSize)
          ..fillRange(0, vectorSize, dbToGain(-6.0));
        final outBuf = Float32List(vectorSize);

        // Closed: exact 0.0 output
        processor.process(context, _expanderInputs(quietBuf), [outBuf]);
        for (int i = 0; i < vectorSize; i++) {
          expect(outBuf[i], equals(0.0));
        }

        // Re-opens cleanly with no NaN or sticky -infinity
        processor.process(context, _expanderInputs(loudBuf), [outBuf]);
        for (int i = 0; i < vectorSize; i++) {
          expect(outBuf[i], closeTo(dbToGain(-6.0), 1e-5));
        }
      },
    );

    test('smooth quadratic knee transitions gently around threshold', () {
      // Threshold: -20 dB, Ratio: 2:1, Knee: 6 dB (region: -23 dB to -17 dB)
      final softExp = ExpanderProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 2.0,
        range: -60.0,
        attack: 0.0,
        hold: 0.0,
        release: 0.0,
        knee: 6.0,
        hysteresis: 0.0,
      );
      final hardExp = ExpanderProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: 2.0,
        range: -60.0,
        attack: 0.0,
        hold: 0.0,
        release: 0.0,
        knee: 0.0,
        hysteresis: 0.0,
      );

      const vectorSize = 4;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      final inBuf = Float32List(vectorSize);
      final outBuf = Float32List(vectorSize);

      // At -18 dB (+2 dB above threshold, inside knee): hard does 0 dB, soft gently reduces
      inBuf.fillRange(0, vectorSize, dbToGain(-18.0));
      hardExp.process(context, _expanderInputs(inBuf), [outBuf]);
      softExp.process(context, _expanderInputs(inBuf), [outBuf]);
      expect(hardExp.gainReductionDb, equals(0.0));
      expect(softExp.gainReductionDb, greaterThan(0.0));
      expect(softExp.gainReductionDb, lessThan(0.2));

      // At threshold (-20 dB): soft knee reduction = (1.0 * 3^2) / 12 = 0.75 dB
      inBuf.fillRange(0, vectorSize, dbToGain(-20.0));
      hardExp.process(context, _expanderInputs(inBuf), [outBuf]);
      softExp.process(context, _expanderInputs(inBuf), [outBuf]);
      expect(hardExp.gainReductionDb, equals(0.0));
      expect(softExp.gainReductionDb, closeTo(0.75, 1e-3));

      // At bottom of knee (-23 dB, 3 dB below threshold): both match 3.0 dB reduction
      inBuf.fillRange(0, vectorSize, dbToGain(-23.0));
      hardExp.process(context, _expanderInputs(inBuf), [outBuf]);
      softExp.process(context, _expanderInputs(inBuf), [outBuf]);
      expect(hardExp.gainReductionDb, closeTo(3.0, 1e-2));
      expect(softExp.gainReductionDb, closeTo(3.0, 1e-2));
    });
  });

  group('NoiseGate hysteresis, hold, and ballistics', () {
    test('hysteresis prevents chatter between open and close thresholds', () {
      // Opens at -20 dB, closes at -26 dB (hysteresis = 6 dB)
      final processor = ExpanderProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: double.infinity,
        range: -60.0,
        attack: 0.0,
        hold: 0.0,
        release: 0.0,
        knee: 0.0,
        hysteresis: 6.0,
      );

      const vectorSize = 4;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);
      final outBuf = Float32List(vectorSize);

      // 1. Starts closed: -23 dB is below open threshold (-20 dB) -> stays closed
      final midBuf = Float32List(vectorSize)
        ..fillRange(0, vectorSize, dbToGain(-23.0));
      processor.process(context, _expanderInputs(midBuf), [outBuf]);
      expect(processor.isOpen, isFalse);
      expect(processor.gainReductionDb, closeTo(60.0, 1e-2));

      // 2. Signal crosses -20 dB (-18 dB) -> opens!
      final highBuf = Float32List(vectorSize)
        ..fillRange(0, vectorSize, dbToGain(-18.0));
      processor.process(context, _expanderInputs(highBuf), [outBuf]);
      expect(processor.isOpen, isTrue);
      expect(processor.gainReductionDb, closeTo(0.0, 1e-4));

      // 3. Signal drops to -23 dB (above close threshold -26 dB) -> stays open!
      processor.process(context, _expanderInputs(midBuf), [outBuf]);
      expect(processor.isOpen, isTrue);
      expect(processor.gainReductionDb, closeTo(0.0, 1e-4));

      // 4. Signal drops below -26 dB (-30 dB) -> closes!
      final lowBuf = Float32List(vectorSize)
        ..fillRange(0, vectorSize, dbToGain(-30.0));
      processor.process(context, _expanderInputs(lowBuf), [outBuf]);
      expect(processor.isOpen, isFalse);
      expect(processor.gainReductionDb, closeTo(60.0, 1e-2));

      // 5. Signal bounces back to -23 dB -> stays closed until >= -20 dB!
      processor.process(context, _expanderInputs(midBuf), [outBuf]);
      expect(processor.isOpen, isFalse);
      expect(processor.gainReductionDb, closeTo(60.0, 1e-2));
    });

    test('hold keeps gate open for configured duration before closing', () {
      const sampleRate = 10000;
      // 10 ms hold = 100 samples
      final processor = ExpanderProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: double.infinity,
        range: -60.0,
        attack: 0.0,
        hold: 0.010,
        release: 0.0,
        knee: 0.0,
        hysteresis: 0.0,
      );

      const vectorSize = 40;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );
      final loudBuf = Float32List(vectorSize)..fillRange(0, vectorSize, 1.0);
      final silentBuf = Float32List(vectorSize);
      final outBuf = Float32List(vectorSize);

      // Open the gate
      processor.process(context, _expanderInputs(loudBuf), [outBuf]);
      expect(processor.isOpen, isTrue);

      // 40 silent samples (< 100 hold) -> still open
      processor.process(context, _expanderInputs(silentBuf), [outBuf]);
      expect(processor.isOpen, isTrue);
      expect(processor.gainReductionDb, closeTo(0.0, 1e-4));

      // 80 silent samples (< 100 hold) -> still open
      processor.process(context, _expanderInputs(silentBuf), [outBuf]);
      expect(processor.isOpen, isTrue);

      // 120 silent samples (> 100 hold) -> now closed
      processor.process(context, _expanderInputs(silentBuf), [outBuf]);
      expect(processor.isOpen, isFalse);
      expect(processor.gainReductionDb, closeTo(60.0, 1e-2));
    });

    test('smooths closing (release) and opening (attack) according to time constants', () {
      const sampleRate = 40000;
      const timeSec = 0.010; // 10 ms = 400 samples
      final processor = ExpanderProcessor(
        numChannels: 1,
        threshold: -20.0,
        ratio: double.infinity,
        range: -60.0,
        attack: timeSec,
        hold: 0.0,
        release: timeSec,
        knee: 0.0,
        hysteresis: 0.0,
      );

      const vectorSize = 400;
      final context = ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      );
      final silentBuf = Float32List(vectorSize);
      final loudBuf = Float32List(vectorSize)..fillRange(0, vectorSize, 1.0);
      final outBuf = Float32List(vectorSize);

      // Release from 0 dB toward -60 dB over 1 time constant -> ~63.2% of 60 dB = ~37.9 dB
      processor.process(context, _expanderInputs(silentBuf), [outBuf]);
      expect(
        processor.gainReductionDb,
        closeTo(60.0 * (1.0 - 1.0 / 2.71828), 0.5),
      );

      // Let it settle near -60 dB
      for (int b = 0; b < 15; b++) {
        processor.process(context, _expanderInputs(silentBuf), [outBuf]);
      }
      expect(processor.gainReductionDb, closeTo(60.0, 0.1));

      // Attack from -60 dB back toward 0 dB over 1 time constant -> ~36.8% remaining = ~22.1 dB
      processor.process(context, _expanderInputs(loudBuf), [outBuf]);
      expect(
        processor.gainReductionDb,
        closeTo(60.0 / 2.71828, 0.5),
      );
    });
  });

  group('Expander stereo linking, sidechain, and AudioPipeline', () {
    test(
      'stereo linking opens both channels when either exceeds threshold',
      () {
        final processor = ExpanderProcessor(
          numChannels: 2,
          threshold: -20.0,
          ratio: double.infinity,
          range: -60.0,
          attack: 0.0,
          hold: 0.0,
          release: 0.0,
          knee: 0.0,
          hysteresis: 0.0,
        );

        const vectorSize = 8;
        final context = ProcessContext(
          sampleRate: 44100,
          vectorSize: vectorSize,
        );
        // Left is loud (-6 dB), right is quiet (-40 dB) -> linked peak is -6 dB -> both pass at unity
        final leftIn = Float32List(vectorSize)
          ..fillRange(0, vectorSize, dbToGain(-6.0));
        final rightIn = Float32List(vectorSize)
          ..fillRange(0, vectorSize, dbToGain(-40.0));
        final leftOut = Float32List(vectorSize);
        final rightOut = Float32List(vectorSize);

        processor.process(
          context,
          _expanderInputs(leftIn, inR: rightIn),
          [leftOut, rightOut],
        );

        for (int i = 0; i < vectorSize; i++) {
          expect(leftOut[i], closeTo(dbToGain(-6.0), 1e-5));
          expect(rightOut[i], closeTo(dbToGain(-40.0), 1e-5));
        }
      },
    );

    test(
      'renders through AudioPipeline and supports sidechain & live updates',
      () {
        final padOsc = SineOscillator(frequency: const .value(440));
        final keyOsc = SineOscillator(frequency: const .value(220));

        final gate = NoiseGate.mono(
          padOsc.outlet,
          sidechain: keyOsc.outlet,
          threshold: const .value(-20.0),
          attack: const .value(0.0),
          hold: const .value(0.0),
          release: const .value(0.0),
          hysteresis: const .value(0.0),
        );
        final out = Out.mono(gate.outlet);

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

        final proc = pipeline.processorOf(gate);
        expect(proc.threshold, equals(-20.0));

        proc.update((
          threshold: -10.0,
          ratio: double.infinity,
          range: -40.0,
          attack: 0.005,
          hold: 0.010,
          release: 0.050,
          knee: 0.0,
          hysteresis: 2.0,
          hasSidechain: true,
        ));
        expect(proc.threshold, equals(-10.0));
        expect(proc.range, equals(-40.0));
        expect(proc.hysteresis, equals(2.0));
      },
    );
  });
}
