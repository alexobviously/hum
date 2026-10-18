import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Tempo and Musical Time', () {
    test('calculates basic note durations at 120 BPM', () {
      final tempo = Tempo(120.0);

      // At 120 BPM:
      // 1 beat (quarter) = 60 / 120 = 0.5 seconds
      expect(tempo.beat, equals(0.5));
      expect(tempo.quarter, equals(0.5));
      expect(tempo.half, equals(1.0));
      expect(tempo.whole, equals(2.0));
      expect(tempo.eighth, equals(0.25));
      expect(tempo.sixteenth, equals(0.125));
      expect(tempo.thirtySecond, equals(0.0625));

      // Bar in 4/4 is 2.0 seconds
      expect(tempo.bar, equals(2.0));
    });

    test('supports different time signatures', () {
      // 3/4 time at 120 BPM: 3 quarter notes = 1.5 seconds
      final tempo34 = Tempo(120.0, (3, 4));
      expect(tempo34.beat, equals(0.5));
      expect(tempo34.bar, equals(1.5));

      // 6/8 time at 120 BPM: 6 eighth notes = 6 * 0.25 = 1.5 seconds
      final tempo68 = Tempo(120.0, (6, 8));
      expect(tempo68.bar, equals(1.5));

      // 7/8 time at 120 BPM: 7 eighth notes = 1.75 seconds
      final tempo78 = Tempo(120.0, (7, 8));
      expect(tempo78.bar, equals(1.75));
    });

    test('calculates dotted and triplet durations', () {
      final tempo = Tempo(120.0);

      // Dotted eighth: 0.25 * 1.5 = 0.375s
      expect(tempo.dottedEighth, equals(0.375));
      expect(tempo.durationOf(NoteValue.eighth, dotted: true), equals(0.375));

      // Triplet quarter: 0.5 * (2/3) = 0.3333...
      expect(tempo.tripletQuarter, closeTo(1.0 / 3.0, 1e-6));
      expect(
        tempo.durationOf(NoteValue.quarter, triplet: true),
        closeTo(1.0 / 3.0, 1e-6),
      );
    });

    test('calculates frequency for LFOs and Clocks', () {
      final tempo = Tempo(120.0);

      // Quarter note is 0.5s => 2.0 Hz
      expect(tempo.frequencyOf(NoteValue.quarter), equals(2.0));

      // Whole note is 2.0s => 0.5 Hz
      expect(tempo.frequencyOf(NoteValue.whole), equals(0.5));

      // Sixteenth note is 0.125s => 8.0 Hz
      expect(tempo.frequencyOf(NoteValue.sixteenth), equals(8.0));
    });

    test('calculates total samples and pipeline blocks', () {
      final tempo = Tempo(140.0);
      const sr = 44100;
      const vs = 64;

      // 4 bars in 4/4 at 140 BPM
      final expectedSeconds = 4.0 * (4.0 * 60.0 / 140.0);
      final expectedSamples = (expectedSeconds * sr).round();

      expect(
        tempo.samplesFor(bars: 4, sampleRate: sr),
        equals(expectedSamples),
      );

      final expectedBlocks = (expectedSamples / vs).ceil();
      expect(
        tempo.blocksFor(bars: 4, sampleRate: sr, vectorSize: vs),
        equals(expectedBlocks),
      );
    });
  });
}
