import 'dart:typed_data';

import 'package:dsp/dsp.dart';
import 'package:test/test.dart';

void main() {
  group('Clock node', () {
    test('declares expected inlets and outlets', () {
      final clock = Clock(
        frequency: const .value(4.0),
        pulseWidth: const .value(0.25),
      );

      expect(clock.inlets.length, equals(2));
      expect(clock.inlets[Clock.freqInlet].index, equals(Clock.freqInlet));
      expect(clock.inlets[Clock.pulseWidthInlet].index, equals(Clock.pulseWidthInlet));
      expect(clock.outlets.length, equals(1));
      expect(clock.outlet, equals(clock.outlets.first));
    });

    test('Clock.bpm sets frequency correctly', () {
      final clock = Clock.bpm(120);
      expect(clock.frequency.valueOrNull, equals(2.0));

      final fastClock = Clock.bpm(240);
      expect(fastClock.frequency.valueOrNull, equals(4.0));
    });

    test('generates unipolar 0.0 and 1.0 pulses with correct duty cycle', () {
      // 10 Hz at 100 Hz sample rate => 10 samples per cycle
      const sampleRate = 100;
      const vectorSize = 10;
      final context = ProcessContext(sampleRate: sampleRate, vectorSize: vectorSize);

      final clock = Clock(
        frequency: const .value(10.0),
        pulseWidth: const .value(0.4), // 40% high (4 samples high, 6 samples low)
      );
      final processor = clock.createProcessor();

      final outputs = [Float32List(vectorSize)];
      processor.process(context, [], outputs);

      // Verify each sample is either 0.0 or 1.0
      for (final s in outputs[0]) {
        expect(s == 0.0 || s == 1.0, isTrue);
      }

      // First 4 samples should be 1.0 (phase < 0.4), remaining 6 samples 0.0
      expect(outputs[0][0], equals(1.0));
      expect(outputs[0][1], equals(1.0));
      expect(outputs[0][2], equals(1.0));
      expect(outputs[0][3], equals(1.0));
      expect(outputs[0][4], equals(0.0));
      expect(outputs[0][5], equals(0.0));
      expect(outputs[0][6], equals(0.0));
      expect(outputs[0][7], equals(0.0));
      expect(outputs[0][8], equals(0.0));
      expect(outputs[0][9], equals(0.0));
    });

    test('can be compiled in AudioPipeline', () {
      final clock = Clock.bpm(120);
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final pipeline = compilePipeline(root: clock, context: context);

      pipeline.process();
      expect(pipeline.outputs.length, equals(1));
      expect(pipeline.outputs[0].length, equals(64));

      // Output should start high at phase 0
      expect(pipeline.outputs[0][0], equals(1.0));
    });
  });
}
