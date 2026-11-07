import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('ScalePattern', () {
    test('defines correct diatonic mode intervals', () {
      expect(ScalePattern.major.intervals, equals([0, 2, 4, 5, 7, 9, 11]));
      expect(ScalePattern.minor.intervals, equals([0, 2, 3, 5, 7, 8, 10]));
      expect(ScalePattern.dorian.intervals, equals([0, 2, 3, 5, 7, 9, 10]));
      expect(ScalePattern.phrygian.intervals, equals([0, 1, 3, 5, 7, 8, 10]));
      expect(ScalePattern.lydian.intervals, equals([0, 2, 4, 6, 7, 9, 11]));
      expect(ScalePattern.mixolydian.intervals, equals([0, 2, 4, 5, 7, 9, 10]));
      expect(ScalePattern.locrian.intervals, equals([0, 1, 3, 5, 6, 8, 10]));
    });

    test('defines correct pentatonic, blues, and other scales', () {
      expect(ScalePattern.majorPentatonic.intervals, equals([0, 2, 4, 7, 9]));
      expect(ScalePattern.minorPentatonic.intervals, equals([0, 3, 5, 7, 10]));
      expect(ScalePattern.blues.intervals, equals([0, 3, 5, 6, 7, 10]));
      expect(
        ScalePattern.harmonicMinor.intervals,
        equals([0, 2, 3, 5, 7, 8, 11]),
      );
      expect(
        ScalePattern.melodicMinor.intervals,
        equals([0, 2, 3, 5, 7, 9, 11]),
      );
      expect(ScalePattern.chromatic.length, equals(12));
      expect(ScalePattern.wholeTone.intervals, equals([0, 2, 4, 6, 8, 10]));
    });
  });

  group('Scale', () {
    test('generates expected notes for base octave', () {
      final cMajor = Scale.major(Note.parse('C4'));
      expect(
        cMajor.notes.map((n) => n.name).toList(),
        equals([
          'C4',
          'D4',
          'E4',
          'F4',
          'G4',
          'A4',
          'B4',
        ]),
      );

      final aMinor = Scale.minor(Note.parse('A3'));
      expect(
        aMinor.notes.map((n) => n.name).toList(),
        equals([
          'A3',
          'B3',
          'C4',
          'D4',
          'E4',
          'F4',
          'G4',
        ]),
      );
    });

    test('take(10) crosses octave boundaries smoothly in ascending order', () {
      final aMinor = Scale.minor(Note.parse('A3'));
      final notes = aMinor.take(10);

      expect(
        notes.map((n) => n.name).toList(),
        equals([
          'A3',
          'B3',
          'C4',
          'D4',
          'E4',
          'F4',
          'G4',
          'A4',
          'B4',
          'C5',
        ]),
      );

      // Verify strictly increasing frequencies
      for (int i = 1; i < notes.length; i++) {
        expect(notes[i].hz, greaterThan(notes[i - 1].hz));
      }
    });

    test('span(octaves: 2) generates two full octaves plus top tonic', () {
      final cMajor = Scale.major(Note.parse('C4'));
      final notes = cMajor.span(octaves: 2);

      expect(notes.length, equals(15)); // 7 * 2 + 1
      expect(notes.first.name, equals('C4'));
      expect(notes[7].name, equals('C5'));
      expect(notes.last.name, equals('C6'));
    });

    test('degree() retrieves notes by 1-indexed scale degree', () {
      final cMajor = Scale.major(Note.parse('C4'));

      expect(cMajor.degree(1).name, equals('C4'));
      expect(cMajor.degree(3).name, equals('E4'));
      expect(cMajor.degree(5).name, equals('G4'));
      expect(cMajor.degree(7).name, equals('B4'));
      expect(cMajor.degree(8).name, equals('C5'));
      expect(cMajor.degree(10).name, equals('E5'));

      expect(() => cMajor.degree(0), throwsArgumentError);
    });

    test('contains() checks pitch class membership', () {
      final cMajor = Scale.major(Note.parse('C4'));

      expect(cMajor.contains(Note.parse('C3')), isTrue);
      expect(cMajor.contains(Note.parse('E5')), isTrue);
      expect(cMajor.contains(Note.parse('B2')), isTrue);

      expect(cMajor.contains(Note.parse('C#4')), isFalse);
      expect(cMajor.contains(Note.parse('F#4')), isFalse);
      expect(cMajor.contains(Note.parse('Bb3')), isFalse);
    });

    test('quantize() snaps MIDI notes to nearest scale note', () {
      final cMajor = Scale.major(
        Note.parse('C4'),
      ); // Notes: C, D, E, F, G, A, B

      // Exact notes stay unchanged
      expect(cMajor.quantize(60).name, equals('C4')); // C4
      expect(cMajor.quantize(62).name, equals('D4')); // D4

      // C# (61) rounds to nearest in scale (C or D)
      final quantized61 = cMajor.quantize(61);
      expect(quantized61.name == 'C4' || quantized61.name == 'D4', isTrue);

      // F#4 (66) rounds to F4 (65) or G4 (67)
      final quantized66 = cMajor.quantize(66);
      expect(quantized66.name == 'F4' || quantized66.name == 'G4', isTrue);

      // Microtonal pitch (64.2 -> E4)
      expect(cMajor.quantize(64.2).name, equals('E4'));
    });

    test('parse() parses note and scale name', () {
      final scale1 = Scale.parse('A3 minor');
      expect(scale1.root.name, equals('A3'));
      expect(scale1.pattern, equals(ScalePattern.minor));

      final scale2 = Scale.parse('F#4 dorian');
      expect(scale2.root.name, equals('F#4'));
      expect(scale2.pattern, equals(ScalePattern.dorian));

      final scale3 = Scale.parse('C4 major pentatonic');
      expect(scale3.pattern, equals(ScalePattern.majorPentatonic));
    });

    test('triad() and seventhChord() build diatonic chords', () {
      final cMajor = Scale.major(Note.parse('C4'));

      // I triad: C - E - G (C major)
      final chord1 = cMajor.triad(1);
      expect(
        chord1.notes.map((n) => n.name).toList(),
        equals(['C4', 'E4', 'G4']),
      );

      // ii triad: D - F - A (D minor)
      final chord2 = cMajor.triad(2);
      expect(
        chord2.notes.map((n) => n.name).toList(),
        equals(['D4', 'F4', 'A4']),
      );

      // V triad: G - B - D (G major)
      final chord5 = cMajor.triad(5);
      expect(
        chord5.notes.map((n) => n.name).toList(),
        equals(['G4', 'B4', 'D5']),
      );

      // vii dim triad: B - D - F (B diminished)
      final chord7 = cMajor.triad(7);
      expect(
        chord7.notes.map((n) => n.name).toList(),
        equals(['B4', 'D5', 'F5']),
      );

      // Imaj7: C - E - G - B
      final maj7 = cMajor.seventhChord(1);
      expect(
        maj7.notes.map((n) => n.name).toList(),
        equals(['C4', 'E4', 'G4', 'B4']),
      );

      // V7: G - B - D - F (G dominant 7)
      final dom7 = cMajor.seventhChord(5);
      expect(
        dom7.notes.map((n) => n.name).toList(),
        equals(['G4', 'B4', 'D5', 'F5']),
      );
    });
  });

  group('Chord', () {
    test('generates expected notes for basic triads', () {
      final cMaj = Chord.major(Note.parse('C4'));
      expect(
        cMaj.notes.map((n) => n.name).toList(),
        equals(['C4', 'E4', 'G4']),
      );
      expect(cMaj.name, equals('C4'));

      final aMin = Chord.minor(Note.parse('A3'));
      expect(
        aMin.notes.map((n) => n.name).toList(),
        equals(['A3', 'C4', 'E4']),
      );
      expect(aMin.name, equals('A3m'));
    });

    test('generates expected notes for 7th chords', () {
      final gDom7 = Chord.dom7(Note.parse('G4'));
      expect(
        gDom7.notes.map((n) => n.name).toList(),
        equals(['G4', 'B4', 'D5', 'F5']),
      );
      expect(gDom7.name, equals('G47'));

      final cMaj7 = Chord.maj7(Note.parse('C4'));
      expect(
        cMaj7.notes.map((n) => n.name).toList(),
        equals(['C4', 'E4', 'G4', 'B4']),
      );

      final dMin7 = Chord.min7(Note.parse('D4'));
      expect(
        dMin7.notes.map((n) => n.name).toList(),
        equals(['D4', 'F4', 'A4', 'C5']),
      );
    });

    test('inversion shifts bass notes up by an octave', () {
      final cMaj = Chord.major(Note.parse('C4'));

      // Root position: C4, E4, G4
      expect(
        cMaj.notes.map((n) => n.name).toList(),
        equals(['C4', 'E4', 'G4']),
      );

      // 1st inversion: E4, G4, C5
      final inv1 = cMaj.invert(1);
      expect(
        inv1.notes.map((n) => n.name).toList(),
        equals(['E4', 'G4', 'C5']),
      );
      expect(inv1.name, equals('C4/E4'));

      // 2nd inversion: G4, C5, E5
      final inv2 = cMaj.invert(2);
      expect(
        inv2.notes.map((n) => n.name).toList(),
        equals(['G4', 'C5', 'E5']),
      );
      expect(inv2.name, equals('C4/G4'));
    });

    test('fluent extensions on Note work seamlessly', () {
      final note = Note.parse('A3');

      final scale = note.minor;
      expect(scale.pattern, equals(ScalePattern.minor));
      expect(
        scale.take(4).map((n) => n.name).toList(),
        equals(['A3', 'B3', 'C4', 'D4']),
      );

      final chord = note.minorChord;
      expect(
        chord.notes.map((n) => n.name).toList(),
        equals(['A3', 'C4', 'E4']),
      );
    });
  });
}
