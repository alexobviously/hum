import 'pitch.dart';

/// The interval pattern defining a chord type, independent of the root note.
class const ChordPattern(
  final String name,
  final String abbreviation,
  final List<int> intervals,
) {
  /// Number of notes in this chord.
  int get length => intervals.length;

  // --- Triads ---

  /// Major triad: `[0, 4, 7]`.
  static const major = ChordPattern('Major', '', [0, 4, 7]);

  /// Minor triad: `[0, 3, 7]`.
  static const minor = ChordPattern('Minor', 'm', [0, 3, 7]);

  /// Diminished triad: `[0, 3, 6]`.
  static const diminished = ChordPattern('Diminished', 'dim', [0, 3, 6]);

  /// Augmented triad: `[0, 4, 8]`.
  static const augmented = ChordPattern('Augmented', 'aug', [0, 4, 8]);

  /// Suspended 2nd triad: `[0, 2, 7]`.
  static const sus2 = ChordPattern('Suspended 2nd', 'sus2', [0, 2, 7]);

  /// Suspended 4th triad: `[0, 5, 7]`.
  static const sus4 = ChordPattern('Suspended 4th', 'sus4', [0, 5, 7]);

  // --- 7th Chords ---

  /// Dominant 7th chord: `[0, 4, 7, 10]`.
  static const dominant7 = ChordPattern('Dominant 7th', '7', [0, 4, 7, 10]);

  /// Major 7th chord: `[0, 4, 7, 11]`.
  static const major7 = ChordPattern('Major 7th', 'maj7', [0, 4, 7, 11]);

  /// Minor 7th chord: `[0, 3, 7, 10]`.
  static const minor7 = ChordPattern('Minor 7th', 'm7', [0, 3, 7, 10]);

  /// Diminished 7th chord: `[0, 3, 6, 9]`.
  static const diminished7 = ChordPattern(
    'Diminished 7th',
    'dim7',
    [0, 3, 6, 9],
  );

  /// Half-diminished 7th chord (m7b5): `[0, 3, 6, 10]`.
  static const halfDiminished7 = ChordPattern(
    'Half-Diminished 7th',
    'm7b5',
    [0, 3, 6, 10],
  );

  @override
  String toString() => name;
}

/// A musical chord defined by root note, pattern, and voicing inversion.
class const Chord(
  /// The root note of this chord.
  final Note root,

  /// The chord pattern intervals.
  final ChordPattern pattern, {

  /// Inversion index (0 = root position, 1 = first inversion, 2 = second inversion, etc.).
  final int inversion = 0,
  final List<Note>? customNotes,
}) {
  /// Creates a chord from an explicit list of notes (e.g. from diatonic scale degree stacking).
  new fromNotes(List<Note> notes)
    : this(notes.first, .major, inversion: 0, customNotes: notes);

  // --- Convenience Factories ---

  factory major(Note root, {int inversion = 0}) =>
      Chord(root, .major, inversion: inversion);

  factory minor(Note root, {int inversion = 0}) =>
      Chord(root, .minor, inversion: inversion);

  factory diminished(Note root, {int inversion = 0}) =>
      Chord(root, .diminished, inversion: inversion);

  factory augmented(Note root, {int inversion = 0}) =>
      Chord(root, .augmented, inversion: inversion);

  factory sus2(Note root, {int inversion = 0}) =>
      Chord(root, .sus2, inversion: inversion);

  factory sus4(Note root, {int inversion = 0}) =>
      Chord(root, .sus4, inversion: inversion);

  factory dom7(Note root, {int inversion = 0}) =>
      Chord(root, .dominant7, inversion: inversion);

  factory maj7(Note root, {int inversion = 0}) =>
      Chord(root, .major7, inversion: inversion);

  factory min7(Note root, {int inversion = 0}) =>
      Chord(root, .minor7, inversion: inversion);

  /// Returns the concrete list of [Note]s comprising this chord, with inversions applied.
  List<Note> get notes {
    if (customNotes != null) return customNotes!;

    final baseNotes = [
      for (final semitones in pattern.intervals) root.transpose(semitones),
    ];

    if (inversion == 0 || baseNotes.isEmpty) return baseNotes;

    // Apply inversion: shift lower notes up by an octave
    final len = baseNotes.length;
    final inv = inversion % len;
    return [
      ...baseNotes.sublist(inv),
      for (int i = 0; i < inv; i++) baseNotes[i].transpose(12),
    ];
  }

  /// Frequencies in Hertz for each voice in this chord.
  List<double> get hz => [for (final n in notes) n.hz];

  /// Integer MIDI note numbers for each voice in this chord.
  List<int> get midi => [for (final n in notes) n.midi];

  /// Transposes the entire chord by [semitones].
  Chord transpose(int semitones) {
    if (customNotes != null) {
      return Chord.fromNotes([
        for (final n in customNotes!) n.transpose(semitones),
      ]);
    }
    return Chord(root.transpose(semitones), pattern, inversion: inversion);
  }

  /// Returns a new [Chord] with the specified [inversion].
  Chord invert(int newInversion) {
    if (customNotes != null) {
      final len = customNotes!.length;
      final inv = newInversion % len;
      return Chord.fromNotes([
        ...customNotes!.sublist(inv),
        for (int i = 0; i < inv; i++) customNotes![i].transpose(12),
      ]);
    }
    return Chord(root, pattern, inversion: newInversion);
  }

  /// Chord symbol name (e.g. `'C'`, `'Am'`, `'G7'`, `'F#m7b5'`).
  String get name {
    if (customNotes != null) {
      return 'Chord(${[for (final n in customNotes!) n.name].join(', ')})';
    }
    final invStr = inversion > 0 ? '/${notes.first.name}' : '';
    return '${root.name}${pattern.abbreviation}$invStr';
  }

  @override
  String toString() => '$name (${[for (final n in notes) n.name].join(' ')})';
}

/// Extensions on [Note] for building chords.
extension NoteChordExtension on Note {
  Chord chord(ChordPattern pattern, {int inversion = 0}) =>
      Chord(this, pattern, inversion: inversion);

  Chord get majorChord => .major(this);
  Chord get minorChord => .minor(this);
  Chord get dom7Chord => .dom7(this);
  Chord get maj7Chord => .maj7(this);
  Chord get min7Chord => .min7(this);
}
