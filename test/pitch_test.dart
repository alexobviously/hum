import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Pitch and Note utilities', () {
    test('converts MIDI to Hz with 440 Hz standard concert pitch', () {
      // Middle C (MIDI 60) -> 261.6255 Hz
      expect(midiToHz(60), closeTo(261.63, 0.01));

      // Concert A4 (MIDI 69) -> 440.0 Hz
      expect(midiToHz(69), equals(440.0));

      // A5 (MIDI 81) -> 880.0 Hz
      expect(midiToHz(81), equals(880.0));

      // A3 (MIDI 57) -> 220.0 Hz
      expect(midiToHz(57), equals(220.0));
    });

    test('supports alternative reference tuning (e.g. 432 Hz)', () {
      // A4 at 432 Hz
      expect(midiToHz(69, 432.0), equals(432.0));

      // Middle C at 432 Hz reference: 432 * 2^((60-69)/12) ~= 256.87 Hz
      expect(midiToHz(60, 432.0), closeTo(256.87, 0.01));

      // Note class with 432 Hz reference
      final note432 = Note.parse('A4', 432.0);
      expect(note432.hz, equals(432.0));
    });

    test('converts Hz back to MIDI note number', () {
      expect(hzToMidi(440.0), closeTo(69.0, 1e-6));
      expect(hzToMidi(261.625565), closeTo(60.0, 1e-3));
      expect(hzToMidi(432.0, 432.0), closeTo(69.0, 1e-6));
    });

    test('parses note strings accurately to MIDI and Hz', () {
      expect(noteToMidi('C4'), equals(60));
      expect(noteToMidi('c4'), equals(60));
      expect(noteToMidi('A4'), equals(69));
      expect(noteToMidi('C#4'), equals(61));
      expect(noteToMidi('Db4'), equals(61));
      expect(noteToMidi('F#3'), equals(54));
      expect(noteToMidi('Gb3'), equals(54));
      expect(noteToMidi('Bb2'), equals(46));
      expect(noteToMidi('A#2'), equals(46));
      expect(noteToMidi('C-1'), equals(0));

      expect(noteToHz('A4'), equals(440.0));
      expect(noteToHz('C4'), closeTo(261.63, 0.01));
    });

    test('converts MIDI numbers to standard note strings', () {
      expect(midiToNote(60), equals('C4'));
      expect(midiToNote(69), equals('A4'));
      expect(midiToNote(61), equals('C#4'));
      expect(midiToNote(61, useSharps: false), equals('Db4'));
    });

    test('Note class provides clean transpositions and intervals', () {
      final root = Note.parse('C4');
      expect(root.midi, equals(60));
      expect(root.hz, closeTo(261.63, 0.01));

      // Transposition
      final d4 = root.transpose(2);
      expect(d4.name, equals('D4'));
      expect(d4.midi, equals(62));

      // Octave shifts
      final c5 = root.upOctave();
      expect(c5.name, equals('C5'));
      expect(c5.midi, equals(72));
      expect(c5.hz, closeTo(root.hz * 2.0, 0.01));

      final c3 = root.downOctave();
      expect(c3.name, equals('C3'));
      expect(c3.midi, equals(48));

      // Musical intervals
      expect(root.fifth.name, equals('G4'));
      expect(root.fourth.name, equals('F4'));
      expect(root.majorThird.name, equals('E4'));
      expect(root.minorThird.name, equals('D#4'));
    });

    test('throws FormatException on malformed note strings', () {
      expect(() => noteToMidi('H4'), throwsFormatException);
      expect(() => noteToMidi('C'), throwsFormatException);
      expect(() => noteToMidi(''), throwsFormatException);
      expect(() => noteToMidi('123'), throwsFormatException);
    });

    test(
      'parses note sequences from whitespace-separated strings and lists',
      () {
        const raw = 'A3 C4 E4 A4';
        final notes = Note.sequence(raw);
        expect(notes.length, equals(4));
        expect(notes.map((n) => n.name), equals(['A3', 'C4', 'E4', 'A4']));

        final hzList = Note.sequenceHz(raw);
        expect(hzList[0], equals(220.0));
        expect(hzList[1], closeTo(261.63, 0.01));
        expect(hzList[3], equals(440.0));

        // String extensions
        expect(raw.toHz(), equals(hzList));
        expect(
          raw.toNotes().map((n) => n.name),
          equals(['A3', 'C4', 'E4', 'A4']),
        );
        expect('A4'.toNote().midi, equals(69));

        // Iterable<String> extensions
        final list = ['F3', 'A3', 'C4'];
        expect(list.toMidi(), equals([53, 57, 60]));
        expect(list.toHz()[1], equals(220.0));
        expect(list.toNotes().map((n) => n.name), equals(['F3', 'A3', 'C4']));
      },
    );
  });
}
