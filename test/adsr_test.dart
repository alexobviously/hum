import 'dart:typed_data';

import 'package:dsp/dsp.dart';
import 'package:test/test.dart';

void main() {
  group('Adsr node', () {
    test('declares expected inlets and outlets', () {
      final dummyClock = Clock.bpm(120);
      final adsr = Adsr(
        gate: dummyClock.outlet,
        attack: const .value(0.02),
        decay: const .value(0.05),
        sustain: const .value(0.6),
        release: const .value(0.1),
      );

      expect(adsr.inlets.length, equals(1));
      expect(adsr.inlets[Adsr.gateInlet].source, equals(dummyClock.outlet));
      expect(adsr.outlets.length, equals(1));
      expect(adsr.outlet, equals(adsr.outlets.first));
    });

    test('stays idle at 0.0 when gate is low', () {
      final dummyClock = Clock.bpm(120);
      final adsr = Adsr(gate: dummyClock.outlet);
      final processor = adsr.createProcessor();

      const vectorSize = 32;
      final context = ProcessContext(sampleRate: 44100, vectorSize: vectorSize);

      final inputs = [Float32List(vectorSize)]; // All zeroes
      final outputs = [Float32List(vectorSize)];

      processor.process(context, inputs, outputs);

      for (int i = 0; i < vectorSize; i++) {
        expect(outputs[0][i], equals(0.0));
      }
      expect(processor.state, equals(AdsrState.idle));
    });

    test('cycles through Attack -> Decay -> Sustain -> Release in linear mode', () {
      const sampleRate = 1000;
      const vectorSize = 100;
      final context = ProcessContext(sampleRate: sampleRate, vectorSize: vectorSize);

      final dummyClock = Clock.bpm(120);
      final adsr = Adsr(
        gate: dummyClock.outlet,
        attack: const .value(0.02), // 20 samples
        decay: const .value(0.03),  // 30 samples
        sustain: const .value(0.5), // holds at 0.5
        release: const .value(0.02), // 20 samples
        curve: AdsrCurve.linear,
      );
      final processor = adsr.createProcessor();

      // Block 1: Gate is held HIGH for 60 samples, then released LOW at sample 60
      final gate1 = Float32List(vectorSize);
      for (int i = 0; i < 60; i++) {
        gate1[i] = 1.0;
      }
      final out1 = [Float32List(vectorSize)];
      processor.process(context, [gate1], out1);

      // Attack phase: starts rising, hits 1.0 around sample 19-20
      expect(out1[0][0], greaterThan(0.0));
      expect(out1[0][19], closeTo(1.0, 0.01));
      expect(out1[0][20], closeTo(1.0, 0.02));

      // Decay phase: falls from 1.0 down to sustain 0.5 around sample 50 (20 + 30)
      expect(out1[0][50], closeTo(0.5, 0.02));

      // Sustain phase: stays at 0.5 until sample 60
      expect(out1[0][58], closeTo(0.5, 0.02));

      // Release phase begins at sample 60: drops to 0.0 by sample 80 (60 + 20)
      expect(out1[0][65], lessThan(0.5));
      expect(out1[0][85], equals(0.0));
      expect(processor.state, equals(AdsrState.idle));
    });

    test('cycles through Attack -> Decay -> Sustain -> Release in exponential mode', () {
      const sampleRate = 1000;
      const vectorSize = 100;
      final context = ProcessContext(sampleRate: sampleRate, vectorSize: vectorSize);

      final dummyClock = Clock.bpm(120);
      final adsr = Adsr(
        gate: dummyClock.outlet,
        attack: const .value(0.015),
        decay: const .value(0.03),
        sustain: const .value(0.4),
        release: const .value(0.02),
        curve: AdsrCurve.exponential,
      );
      final processor = adsr.createProcessor();

      final gate = Float32List(vectorSize);
      for (int i = 0; i < 60; i++) {
        gate[i] = 1.0;
      }
      final out = [Float32List(vectorSize)];
      processor.process(context, [gate], out);

      // Reaches peak 1.0
      double peak = 0.0;
      for (int i = 0; i < 60; i++) {
        if (out[0][i] > peak) peak = out[0][i];
      }
      expect(peak, closeTo(1.0, 0.01));

      // Decays toward sustain level 0.4
      expect(out[0][55], closeTo(0.4, 0.05));

      // Discharges to 0.0 during release
      expect(out[0][95], equals(0.0));
      expect(processor.state, equals(AdsrState.idle));
    });

    test('smoothly retriggers from current level without pops or clicks', () {
      const sampleRate = 1000;
      const vectorSize = 50;
      final context = ProcessContext(sampleRate: sampleRate, vectorSize: vectorSize);

      final dummyClock = Clock.bpm(120);
      final adsr = Adsr(
        gate: dummyClock.outlet,
        attack: const .value(0.02),
        decay: const .value(0.02),
        sustain: const .value(0.5),
        release: const .value(0.05),
      );
      final processor = adsr.createProcessor();

      // Trigger note on, then release at sample 25
      final gate1 = Float32List(vectorSize);
      for (int i = 0; i < 25; i++) {
        gate1[i] = 1.0;
      }
      final out1 = [Float32List(vectorSize)];
      processor.process(context, [gate1], out1);

      // Envelope is releasing mid-way at sample 49
      final releaseLevel = out1[0][49];
      expect(releaseLevel, greaterThan(0.1));
      expect(processor.state, equals(AdsrState.release));

      // Re-trigger note on immediately at sample 0 of block 2
      final gate2 = Float32List(vectorSize);
      for (int i = 0; i < vectorSize; i++) {
        gate2[i] = 1.0;
      }
      final out2 = [Float32List(vectorSize)];
      processor.process(context, [gate2], out2);

      // First sample of re-trigger should start smoothly near releaseLevel, not jump to 0.0!
      expect(out2[0][0], greaterThan(releaseLevel));
      expect(out2[0][0], lessThan(releaseLevel + 0.15));

      // Output reaches peak 1.0 during attack, then decays toward sustain 0.5
      double peak = 0.0;
      for (int i = 0; i < vectorSize; i++) {
        if (out2[0][i] > peak) peak = out2[0][i];
      }
      expect(peak, closeTo(1.0, 0.01));
      expect(out2[0][45], closeTo(0.5, 0.05));
    });

    test('wires together Clock and Adsr in an AudioPipeline', () {
      final clock = Clock.bpm(120, pulseWidth: const .value(0.5));
      final adsr = Adsr(
        gate: clock.outlet,
        attack: const .value(0.01),
        decay: const .value(0.02),
        sustain: const .value(0.5),
        release: const .value(0.02),
      );

      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final pipeline = compilePipeline(root: adsr, context: context);

      pipeline.process();
      expect(pipeline.outputs.length, equals(1));
      expect(pipeline.outputs[0].length, equals(64));

      // Because clock starts high, adsr immediately enters attack and starts rising
      expect(pipeline.outputs[0][0], greaterThan(0.0));
      expect(pipeline.outputs[0][63], greaterThan(pipeline.outputs[0][0]));
    });
  });
}
