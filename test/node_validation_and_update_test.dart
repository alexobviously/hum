import 'dart:math' as math;

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  final osc1 = SineOscillator(frequency: const .value(440));
  final osc2 = SineOscillator(frequency: const .value(880));
  final clock = Clock();

  group('Delay canUpdate and errors', () {
    test('canUpdate succeeds for matching maxDelay and numChannels', () {
      final delay1 = Delay.mono(input: osc1.outlet, maxDelay: 5.0);
      final delay2 = Delay.mono(
        input: osc1.outlet,
        time: const .value(0.2),
        maxDelay: 5.0,
      );

      expect(delay1.canUpdate(delay2), isTrue);
      expect(delay1.errors, isEmpty);
    });

    test('canUpdate fails when maxDelay or numChannels differ', () {
      final mono5s = Delay.mono(input: osc1.outlet, maxDelay: 5.0);
      final mono10s = Delay.mono(input: osc1.outlet, maxDelay: 10.0);
      final stereo5s = Delay.stereo(
        leftInput: osc1.outlet,
        rightInput: osc2.outlet,
        maxDelay: 5.0,
      );

      expect(mono5s.canUpdate(mono10s), isFalse);
      expect(mono5s.canUpdate(stereo5s), isFalse);
    });
  });

  group('CombFilter canUpdate and errors', () {
    test('canUpdate succeeds for matching minFrequency and numChannels', () {
      final filter1 = CombFilter.mono(input: osc1.outlet, minFrequency: 30.0);
      final filter2 = CombFilter.mono(
        input: osc1.outlet,
        frequency: const .value(220),
        minFrequency: 30.0,
      );

      expect(filter1.canUpdate(filter2), isTrue);
      expect(filter1.errors, isEmpty);
    });

    test('canUpdate fails when minFrequency or numChannels differ', () {
      final mono30 = CombFilter.mono(input: osc1.outlet, minFrequency: 30.0);
      final mono50 = CombFilter.mono(input: osc1.outlet, minFrequency: 50.0);
      final stereo30 = CombFilter.stereo(
        leftInput: osc1.outlet,
        rightInput: osc2.outlet,
        minFrequency: 30.0,
      );

      expect(mono30.canUpdate(mono50), isFalse);
      expect(mono30.canUpdate(stereo30), isFalse);
    });
  });

  group('Chorus canUpdate and errors', () {
    test('canUpdate succeeds for matching structural params', () {
      final c1 = Chorus.stereo(
        leftInput: osc1.outlet,
        rightInput: osc2.outlet,
        maxDelay: 0.05,
        stereoPhase: math.pi * 0.5,
      );
      final c2 = Chorus.stereo(
        leftInput: osc1.outlet,
        rightInput: osc2.outlet,
        rate: const .value(2.0),
        maxDelay: 0.05,
        stereoPhase: math.pi * 0.5,
      );

      expect(c1.canUpdate(c2), isTrue);
      expect(c1.errors, isEmpty);
    });

    test('canUpdate fails when structural params differ', () {
      final base = Chorus.stereo(
        leftInput: osc1.outlet,
        rightInput: osc2.outlet,
        maxDelay: 0.05,
        stereoPhase: math.pi * 0.5,
      );
      final diffDelay = Chorus.stereo(
        leftInput: osc1.outlet,
        rightInput: osc2.outlet,
        maxDelay: 0.1,
        stereoPhase: math.pi * 0.5,
      );
      final diffPhase = Chorus.stereo(
        leftInput: osc1.outlet,
        rightInput: osc2.outlet,
        maxDelay: 0.05,
        stereoPhase: math.pi,
      );
      final monoChorus = Chorus.mono(input: osc1.outlet, maxDelay: 0.05);

      expect(base.canUpdate(diffDelay), isFalse);
      expect(base.canUpdate(diffPhase), isFalse);
      expect(base.canUpdate(monoChorus), isFalse);
    });
  });

  group('Freeverb canUpdate and errors', () {
    test('canUpdate succeeds when input channel count matches', () {
      final mono1 = Freeverb.mono(input: osc1.outlet);
      final mono2 = Freeverb.mono(
        input: osc1.outlet,
        roomSize: const .value(0.8),
      );
      final stereo = Freeverb.stereo(left: osc1.outlet, right: osc2.outlet);

      expect(mono1.canUpdate(mono2), isTrue);
      expect(mono1.canUpdate(stereo), isFalse);
      expect(mono1.errors, isEmpty);
      expect(stereo.errors, isEmpty);
    });
  });

  group('Sum canUpdate and errors', () {
    test('canUpdate succeeds when input counts match', () {
      final sum1 = Sum.pair(osc1.outlet, osc2.outlet);
      final sum2 = Sum.pair(osc2.outlet, osc1.outlet);
      final sum3 = Sum.of([osc1.outlet, osc2.outlet, osc1.outlet]);

      expect(sum1.canUpdate(sum2), isTrue);
      expect(sum1.canUpdate(sum3), isFalse);
      expect(sum1.errors, isEmpty);
    });

    test('errors reports empty inputs', () {
      final emptySum = Sum(inputs: const []);
      expect(emptySum.errors, isNotEmpty);
      expect(emptySum.errors.first, isA<AudioNodeParamError>());
      final err = emptySum.errors.first as AudioNodeParamError;
      expect(err.param, equals('inputs'));
    });
  });

  group('Crossfade canUpdate and errors', () {
    test('canUpdate succeeds when numChannels match, even if mode differs', () {
      final cf1 = Crossfade.mono(
        a: osc1.outlet,
        b: osc2.outlet,
        mode: CrossfadeMode.equalPower,
      );
      final cf2 = Crossfade.mono(
        a: osc1.outlet,
        b: osc2.outlet,
        mode: CrossfadeMode.linear,
      );
      final cfStereo = Crossfade.stereo(
        aLeft: osc1.outlet,
        aRight: osc2.outlet,
        bLeft: osc1.outlet,
        bRight: osc2.outlet,
      );

      expect(cf1.canUpdate(cf2), isTrue);
      expect(cf1.canUpdate(cfStereo), isFalse);
      expect(cf1.errors, isEmpty);
    });

    test('errors reports empty or mismatched channels', () {
      final emptyA = Crossfade(a: const [], b: const []);
      expect(emptyA.errors, isNotEmpty);
    });
  });

  group('StepSequencer canUpdate and errors', () {
    test('canUpdate succeeds when reset configuration matches', () {
      final seq1 = StepSequencer.fromList(clock: clock.gate, steps: [100, 200]);
      final seq2 = StepSequencer.fromList(
        clock: clock.gate,
        steps: [300, 400, 500],
      );
      final seqWithReset = StepSequencer.fromList(
        clock: clock.gate,
        reset: clock.trigger,
        steps: [100, 200],
      );

      expect(seq1.canUpdate(seq2), isTrue);
      expect(seq1.canUpdate(seqWithReset), isFalse);
      expect(seq1.errors, isEmpty);
    });

    test('errors reports empty steps', () {
      final emptySeq = StepSequencer.fromList(
        clock: clock.gate,
        steps: const [],
      );
      expect(emptySeq.errors, isNotEmpty);
      final err = emptySeq.errors.first as AudioNodeParamError;
      expect(err.param, equals('steps'));
    });
  });

  group('Max and Min canUpdate and errors', () {
    test('Max canUpdate succeeds when channels count and hasValue match', () {
      final max1 = Max.mono(osc1.outlet, const .value(0.5));
      final max2 = Max.mono(osc1.outlet, const .value(0.8));
      final maxPair = Max.pair(osc1.outlet, osc2.outlet);
      final maxStereo = Max.stereo(
        osc1.outlet,
        osc2.outlet,
        const .value(0.5),
      );

      expect(max1.canUpdate(max2), isTrue);
      expect(max1.canUpdate(maxPair), isFalse);
      expect(max1.canUpdate(maxStereo), isFalse);
      expect(max1.errors, isEmpty);
    });

    test('Max errors reports empty channels', () {
      final emptyMax = Max(channels: const []);
      expect(emptyMax.errors, isNotEmpty);
    });

    test('Min canUpdate succeeds when channels count and hasValue match', () {
      final min1 = Min.mono(osc1.outlet, const .value(0.5));
      final min2 = Min.mono(osc1.outlet, const .value(0.2));
      final minPair = Min.pair(osc1.outlet, osc2.outlet);

      expect(min1.canUpdate(min2), isTrue);
      expect(min1.canUpdate(minPair), isFalse);
      expect(min1.errors, isEmpty);
    });

    test('Min errors reports empty channels', () {
      final emptyMin = Min(channels: const []);
      expect(emptyMin.errors, isNotEmpty);
    });
  });

  group('WavSink canUpdate and errors', () {
    test('canUpdate checks path, channels length, and format', () {
      final sink1 = WavSink.memory(channels: [osc1.outlet]);
      final sink2 = WavSink.memory(channels: [osc2.outlet]);
      final sinkStereo = WavSink.memory(channels: [osc1.outlet, osc2.outlet]);
      final sink16bit = WavSink.memory(
        channels: [osc1.outlet],
        format: WavFormat.pcm16,
      );
      final sinkFile = WavSink.file(
        channels: [osc1.outlet],
        path: '/tmp/test.wav',
      );

      expect(sink1.canUpdate(sink2), isTrue);
      expect(sink1.canUpdate(sinkStereo), isFalse);
      expect(sink1.canUpdate(sink16bit), isFalse);
      expect(sink1.canUpdate(sinkFile), isFalse);
      expect(sink1.errors, isEmpty);
    });

    test('errors reports empty channels', () {
      final emptySink = WavSink.memory(channels: const []);
      expect(emptySink.errors, isNotEmpty);
    });
  });

  group('Bitcrusher canUpdate', () {
    test('canUpdate checks numChannels', () {
      final bcMono1 = Bitcrusher.mono(input: osc1.outlet);
      final bcMono2 = Bitcrusher.mono(
        input: osc1.outlet,
        bitDepth: const .value(8),
      );
      final bcStereo = Bitcrusher.stereo(
        left: osc1.outlet,
        right: osc2.outlet,
      );

      expect(bcMono1.canUpdate(bcMono2), isTrue);
      expect(bcMono1.canUpdate(bcStereo), isFalse);
    });
  });
}
