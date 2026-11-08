import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Decibel Math Utilities', () {
    test('converts decibels to linear amplitude gain', () {
      expect(dbToGain(0.0), closeTo(1.0, 1e-6));
      expect(dbToGain(-6.0205999), closeTo(0.5, 1e-4));
      expect(dbToGain(6.0205999), closeTo(2.0, 1e-4));
      expect(dbToGain(-20.0), closeTo(0.1, 1e-6));
      expect(dbToGain(-40.0), closeTo(0.01, 1e-6));
      expect(dbToGain(-120.0), closeTo(1e-6, 1e-9));
    });

    test('converts linear amplitude gain to decibels', () {
      expect(gainToDb(1.0), closeTo(0.0, 1e-6));
      expect(gainToDb(0.5), closeTo(-6.0205999, 1e-4));
      expect(gainToDb(2.0), closeTo(6.0205999, 1e-4));
      expect(gainToDb(0.1), closeTo(-20.0, 1e-6));
      expect(gainToDb(0.01), closeTo(-40.0, 1e-6));
    });

    test('handles silence and sub-floor values safely', () {
      expect(gainToDb(0.0), equals(-120.0));
      expect(gainToDb(-0.5), equals(-120.0));
      expect(gainToDb(1e-8), equals(-120.0));
      expect(gainToDb(0.0, minDb: -144.0), equals(-144.0));
    });

    test('round-trips decibels and gain accurately', () {
      final testValues = [-60.0, -36.0, -18.0, -6.0, 0.0, 3.0, 12.0];
      for (final db in testValues) {
        final gain = dbToGain(db);
        expect(gainToDb(gain), closeTo(db, 1e-6));
      }
    });

    test('fluent extension properties .db and .toDb work correctly', () {
      expect(0.db, closeTo(1.0, 1e-6));
      expect((-6.0205999).db, closeTo(0.5, 1e-4));
      expect(6.0205999.db, closeTo(2.0, 1e-4));
      expect((-20).db, closeTo(0.1, 1e-6));

      expect(1.0.toDb, closeTo(0.0, 1e-6));
      expect(0.5.toDb, closeTo(-6.0205999, 1e-4));
      expect(0.0.toDb, equals(-120.0));
    });
  });
}
