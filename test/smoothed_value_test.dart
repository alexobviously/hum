import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('SmoothedValue', () {
    test('initializes as settled at initial value', () {
      final smoother = SmoothedValue(100.0);
      expect(smoother.current, equals(100.0));
      expect(smoother.target, equals(100.0));
      expect(smoother.isSettled, isTrue);
      expect(smoother.next(), equals(100.0));
    });

    test('snapTo teleports immediately with zero glide', () {
      final smoother = SmoothedValue(0.0);
      smoother.snapTo(440.0);
      expect(smoother.current, equals(440.0));
      expect(smoother.target, equals(440.0));
      expect(smoother.isSettled, isTrue);
      expect(smoother.next(), equals(440.0));
    });

    test('glides smoothly towards new target', () {
      final smoother = SmoothedValue(0.0);
      smoother.configure(sampleRate: 1000.0, rampTime: 0.1); // 100 samples ramp
      smoother.setTarget(1.0);

      expect(smoother.isSettled, isFalse);

      final first = smoother.next();
      expect(first, greaterThan(0.0));
      expect(first, lessThan(1.0));

      double prev = first;
      // Advance 50 samples
      for (int i = 0; i < 50; i++) {
        final val = smoother.next();
        expect(val, greaterThan(prev));
        prev = val;
      }

      // Eventually settles at target
      for (int i = 0; i < 1000; i++) {
        smoother.next();
      }

      expect(smoother.current, equals(1.0));
      expect(smoother.isSettled, isTrue);
      expect(smoother.next(), equals(1.0));
    });

    test('zero ramp time snaps immediately', () {
      final smoother = SmoothedValue(10.0);
      smoother.configure(sampleRate: 44100.0, rampTime: 0.0);
      smoother.setTarget(50.0);

      expect(smoother.next(), equals(50.0));
      expect(smoother.isSettled, isTrue);
    });

    test('skip advances smoothing ahead', () {
      final s1 = SmoothedValue(0.0);
      final s2 = SmoothedValue(0.0);

      s1.configure(sampleRate: 1000.0, rampTime: 0.1);
      s2.configure(sampleRate: 1000.0, rampTime: 0.1);

      s1.setTarget(10.0);
      s2.setTarget(10.0);

      // Advance s1 sample-by-sample
      for (int i = 0; i < 64; i++) {
        s1.next();
      }

      // Advance s2 via skip
      s2.skip(64);

      expect(s2.current, closeTo(s1.current, 1e-4));
    });
  });
}
