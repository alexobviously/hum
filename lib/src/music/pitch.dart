import 'dart:math' as math;

/// Converts a MIDI note number to frequency in Hertz based on reference pitch [a4].
///
/// Uses standard 12-Tone Equal Temperament (12-TET). Supports fractional
/// MIDI note numbers for microtonal pitch bending and detuning.
///
/// Default reference pitch is concert pitch A4 = 440.0 Hz. Alternative
/// tunings (e.g. 432.0 Hz) can be specified via [a4].
double midiToHz(num midiNote, [double a4 = 440.0]) {
  return a4 * math.pow(2.0, (midiNote - 69.0) / 12.0).toDouble();
}

/// Converts a frequency in Hertz to the corresponding MIDI note number.
///
/// Default reference pitch is concert pitch A4 = 440.0 Hz.
double hzToMidi(double hz, [double a4 = 440.0]) {
  // haha nice
  return 69.0 + 12.0 * (math.log(hz / a4) / math.ln2);
}

/// Converts a note name (e.g. 'C4', 'A4', 'F#3', 'Bb2', 'Eb-1') to its MIDI note number.
///
/// Supports sharps ('#', '♯'), flats ('b', '♭'), and case-insensitive letters.
/// Standard convention: C4 is MIDI note 60 (Middle C), A4 is MIDI note 69 (440 Hz).
int noteToMidi(String note) {
  final match = RegExp(r'^([A-Ga-g])([#b♯♭]?)(-?\d+)$').firstMatch(note.trim());
  if (match == null) {
    throw FormatException(
      'Invalid musical note format: "$note". Expected format like "C4", "A#3", "Bb2".',
    );
  }

  final letter = match.group(1)!.toUpperCase();
  final accidental = match.group(2) ?? '';
  final octave = int.parse(match.group(3)!);

  final baseSemitone = switch (letter) {
    'C' => 0,
    'D' => 2,
    'E' => 4,
    'F' => 5,
    'G' => 7,
    'A' => 9,
    'B' => 11,
    _ => throw FormatException('Invalid note letter: $letter'),
  };

  final accidentalOffset = switch (accidental) {
    '#' || '♯' => 1,
    'b' || '♭' => -1,
    _ => 0,
  };

  return (octave + 1) * 12 + baseSemitone + accidentalOffset;
}

/// Converts a note name (e.g. 'C4', 'A4', 'F#3', 'Bb2') directly to frequency in Hertz.
///
/// Default reference pitch is concert pitch A4 = 440.0 Hz.
double noteToHz(String note, [double a4 = 440.0]) {
  return midiToHz(noteToMidi(note), a4);
}

const List<String> _sharpNoteNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', //
  'F#', 'G', 'G#', 'A', 'A#', 'B',
];

const List<String> _flatNoteNames = [
  'C', 'Db', 'D', 'Eb', 'E', 'F', //
  'Gb', 'G', 'Ab', 'A', 'Bb', 'B',
];

/// Converts an integer MIDI note number to its standard note name string.
///
/// For example: 60 -> 'C4', 69 -> 'A4', 61 -> 'C#4' (or 'Db4' if [useSharps] is false).
String midiToNote(int midiNote, {bool useSharps = true}) {
  final octave = (midiNote ~/ 12) - 1;
  final semitone = ((midiNote % 12) + 12) % 12;
  final names = useSharps ? _sharpNoteNames : _flatNoteNames;
  return '${names[semitone]}$octave';
}

/// A musical pitch representation supporting MIDI, frequency, transposition, and tuning.
class const Note(
  final int midi, [
  final double a4 = 440.0,
]) {
  /// Parses a note name string like 'C4', 'A4', 'F#3', 'Bb2'.
  factory parse(String name, [double a4 = 440.0]) => Note(noteToMidi(name), a4);

  factory hz(double frequency, [double a4 = 440.0]) =>
      Note(hzToMidi(frequency, a4).round(), a4);

  /// Frequency in Hertz according to 12-TET and [a4].
  double get hz => midiToHz(midi, a4);

  /// Standard note name string (e.g. 'C4', 'A4').
  String get name => midiToNote(midi);

  /// Transposes this note by a number of [semitones].
  Note transpose(int semitones) => Note(midi + semitones, a4);

  /// Transposes up by [octaves] (1 octave = 12 semitones).
  Note upOctave([int octaves = 1]) => transpose(12 * octaves);

  /// Transposes down by [octaves].
  Note downOctave([int octaves = 1]) => transpose(-12 * octaves);

  /// Transposes up by a musical fifth (7 semitones).
  Note get fifth => transpose(7);

  /// Transposes up by a musical fourth (5 semitones).
  Note get fourth => transpose(5);

  /// Transposes up by a major third (4 semitones).
  Note get majorThird => transpose(4);

  /// Transposes up by a minor third (3 semitones).
  Note get minorThird => transpose(3);

  @override
  String toString() => '$name ($hz Hz)';
}
