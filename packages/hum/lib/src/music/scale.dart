import 'chord.dart';
import 'pitch.dart';

/// The interval pattern defining a musical scale, independent of the root note.
///
/// Intervals are specified as semitone offsets from the root (where root is 0).
class const ScalePattern(
  final String name,
  final List<int> intervals,
) {
  /// Number of notes per octave in this scale.
  int get length => intervals.length;

  /// Creates a [Scale] using this pattern starting from [root].
  Scale at(Note root) => Scale(root, this);

  // --- Diatonic Modes ---

  /// Major scale (Ionian mode): `[0, 2, 4, 5, 7, 9, 11]`.
  static const major = ScalePattern('Major', [0, 2, 4, 5, 7, 9, 11]);

  /// Natural minor scale (Aeolian mode): `[0, 2, 3, 5, 7, 8, 10]`.
  static const minor = ScalePattern('Natural Minor', [0, 2, 3, 5, 7, 8, 10]);

  /// Dorian mode: `[0, 2, 3, 5, 7, 9, 10]`.
  static const dorian = ScalePattern('Dorian', [0, 2, 3, 5, 7, 9, 10]);

  /// Phrygian mode: `[0, 1, 3, 5, 7, 8, 10]`.
  static const phrygian = ScalePattern('Phrygian', [0, 1, 3, 5, 7, 8, 10]);

  /// Lydian mode: `[0, 2, 4, 6, 7, 9, 11]`.
  static const lydian = ScalePattern('Lydian', [0, 2, 4, 6, 7, 9, 11]);

  /// Mixolydian mode: `[0, 2, 4, 5, 7, 9, 10]`.
  static const mixolydian = ScalePattern('Mixolydian', [0, 2, 4, 5, 7, 9, 10]);

  /// Locrian mode: `[0, 1, 3, 5, 6, 8, 10]`.
  static const locrian = ScalePattern('Locrian', [0, 1, 3, 5, 6, 8, 10]);

  // --- Other Minor Scales ---

  /// Harmonic minor scale: `[0, 2, 3, 5, 7, 8, 11]`.
  static const harmonicMinor = ScalePattern(
    'Harmonic Minor',
    [0, 2, 3, 5, 7, 8, 11],
  );

  /// Melodic minor scale (ascending): `[0, 2, 3, 5, 7, 9, 11]`.
  static const melodicMinor = ScalePattern(
    'Melodic Minor',
    [0, 2, 3, 5, 7, 9, 11],
  );

  // --- Pentatonics & Blues ---

  /// Major pentatonic scale: `[0, 2, 4, 7, 9]`.
  static const majorPentatonic = ScalePattern(
    'Major Pentatonic',
    [0, 2, 4, 7, 9],
  );

  /// Minor pentatonic scale: `[0, 3, 5, 7, 10]`.
  static const minorPentatonic = ScalePattern(
    'Minor Pentatonic',
    [0, 3, 5, 7, 10],
  );

  /// Blues scale (hexatonic with blue note): `[0, 3, 5, 6, 7, 10]`.
  static const blues = ScalePattern('Blues', [0, 3, 5, 6, 7, 10]);

  // --- Symmetric & Modern ---

  /// Full chromatic scale (12 semitones): `[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]`.
  static const chromatic = ScalePattern(
    'Chromatic',
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
  );

  /// Whole-tone scale: `[0, 2, 4, 6, 8, 10]`.
  static const wholeTone = ScalePattern('Whole Tone', [0, 2, 4, 6, 8, 10]);

  @override
  String toString() => name;
}

/// A musical scale grounded on a [root] note and shaped by a [pattern].
class const Scale(
  /// The root / tonic note of this scale.
  final Note root,

  /// The interval formula of this scale.
  final ScalePattern pattern,
) {
  // --- Convenience Factories ---

  factory major(Note root) => Scale(root, .major);
  factory minor(Note root) => Scale(root, .minor);
  factory dorian(Note root) => Scale(root, .dorian);
  factory phrygian(Note root) => Scale(root, .phrygian);
  factory lydian(Note root) => Scale(root, .lydian);
  factory mixolydian(Note root) => Scale(root, .mixolydian);
  factory locrian(Note root) => Scale(root, .locrian);
  factory harmonicMinor(Note root) => Scale(root, .harmonicMinor);
  factory melodicMinor(Note root) => Scale(root, .melodicMinor);
  factory majorPentatonic(Note root) => Scale(root, .majorPentatonic);
  factory minorPentatonic(Note root) => Scale(root, .minorPentatonic);
  factory blues(Note root) => Scale(root, .blues);
  factory chromatic(Note root) => Scale(root, .chromatic);
  factory wholeTone(Note root) => Scale(root, .wholeTone);

  /// Parses a string like `'C4 major'`, `'A3 minor'`, `'D#3 dorian'`.
  factory parse(String input, [double a4 = 440.0]) {
    final parts = input.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) {
      throw FormatException('Invalid scale string: "$input"');
    }
    final root = Note.parse(parts[0], a4);
    if (parts.length == 1) {
      return Scale.major(root);
    }

    final patternName = parts.sublist(1).join(' ').toLowerCase();
    final ScalePattern pattern = switch (patternName) {
      'major' || 'ionian' => .major,
      'minor' || 'natural minor' || 'aeolian' => .minor,
      'dorian' => .dorian,
      'phrygian' => .phrygian,
      'lydian' => .lydian,
      'mixolydian' => .mixolydian,
      'locrian' => .locrian,
      'harmonic minor' => .harmonicMinor,
      'melodic minor' => .melodicMinor,
      'major pentatonic' => .majorPentatonic,
      'minor pentatonic' => .minorPentatonic,
      'blues' => .blues,
      'chromatic' => .chromatic,
      'whole tone' || 'wholetone' => .wholeTone,
      _ => throw FormatException('Unknown scale pattern: "$patternName"'),
    };

    return Scale(root, pattern);
  }

  /// The notes of the scale within the single base octave starting at [root].
  List<Note> get notes => [
    for (final semitones in pattern.intervals) root.transpose(semitones),
  ];

  /// Frequencies in Hertz for the notes of the single base octave.
  List<double> get hz => [for (final n in notes) n.hz];

  /// Integer MIDI numbers for the notes of the single base octave.
  List<int> get midi => [for (final n in notes) n.midi];

  /// Returns [count] ascending notes in this scale, crossing octave boundaries as needed.
  ///
  /// For example, `Scale.minor(Note.parse('A3')).take(10)` returns:
  /// `[A3, B3, C4, D4, E4, F4, G4, A4, B4, C5]`.
  List<Note> take(int count, {int startDegree = 1}) {
    if (count <= 0) return const [];
    final intervals = pattern.intervals;
    final numPerOctave = intervals.length;
    final offset = startDegree - 1;

    Note transpose(int degree) {
      final totalDegree = offset + degree;
      final octave = totalDegree ~/ numPerOctave;
      final step = totalDegree % numPerOctave;
      return root.transpose(octave * 12 + intervals[step]);
    }

    return [
      for (int i = 0; i < count; i++) transpose(i),
    ];
  }

  /// Returns all notes of this scale spanning [octaves] (default 1).
  ///
  /// If [includeRootOctaveAbove] is true (default), the tonic note of the final
  /// octave boundary is appended at the end (e.g. C4 to C5 for an 8-note octave).
  List<Note> span({int octaves = 1, bool includeRootOctaveAbove = true}) {
    if (octaves <= 0) return const [];
    final count = octaves * pattern.length;
    final list = take(count);
    if (includeRootOctaveAbove) {
      return [...list, root.transpose(octaves * 12)];
    }
    return list;
  }

  /// Returns the [Note] at the 1-indexed musical scale [degree].
  ///
  /// `degree(1)` is the root / tonic.
  /// `degree(3)` is the third degree.
  /// `degree(8)` is the tonic an octave above.
  /// Negative degrees step downwards below the root.
  Note degree(int degree) {
    if (degree == 0) {
      throw ArgumentError.value(
        degree,
        'degree',
        'Scale degree is 1-indexed (cannot be 0).',
      );
    }
    final intervals = pattern.intervals;
    final numPerOctave = intervals.length;

    final zeroBased = degree > 0 ? degree - 1 : degree;
    final octave = zeroBased ~/ numPerOctave;
    int step = zeroBased % numPerOctave;
    if (step < 0) step += numPerOctave;

    return root.transpose(octave * 12 + intervals[step]);
  }

  /// Returns `true` if [note] belongs to this scale (by pitch class).
  bool contains(Note note) {
    final pitchClass = ((note.midi - root.midi) % 12 + 12) % 12;
    return pattern.intervals.contains(pitchClass);
  }

  /// Quantizes an arbitrary (even floating-point / microtonal) MIDI note number
  /// to the nearest note in this scale.
  ///
  /// Extremely useful for pitch quantization in generative and random sequencers.
  Note quantize(num midiNote) {
    final noteMidi = midiNote.round();
    final octave = ((noteMidi - root.midi) ~/ 12);
    final pitchClass = ((noteMidi - root.midi) % 12 + 12) % 12;

    // Find the closest interval in the pattern
    int bestInterval = pattern.intervals.first;
    int minDiff = 999;

    for (final interval in pattern.intervals) {
      final diff = (pitchClass - interval).abs();
      if (diff < minDiff) {
        minDiff = diff;
        bestInterval = interval;
      }
    }

    // Also check wrapped distance to upper root (12)
    final wrapDiff = (12 - pitchClass).abs();
    if (wrapDiff < minDiff) {
      return root.transpose((octave + 1) * 12);
    }

    return root.transpose(octave * 12 + bestInterval);
  }

  /// Quantizes a frequency in Hertz to the nearest note frequency in this scale.
  double quantizeHz(double frequency) {
    return quantize(hzToMidi(frequency, root.a4)).hz;
  }

  /// Returns the diatonic triad built on the 1-indexed scale [degree].
  ///
  /// For example in C major:
  /// - `degree 1`: C - E - G (C major)
  /// - `degree 2`: D - F - A (D minor)
  /// - `degree 5`: G - B - D (G major)
  /// - `degree 7`: B - D - F (B diminished)
  Chord triad(int degree) => .fromNotes([
    this.degree(degree),
    this.degree(degree + 2),
    this.degree(degree + 4),
  ]);

  /// Returns the diatonic 7th chord built on the 1-indexed scale [degree].
  Chord seventhChord(int degree) => .fromNotes([
    this.degree(degree),
    this.degree(degree + 2),
    this.degree(degree + 4),
    this.degree(degree + 6),
  ]);

  @override
  String toString() => '${root.name} ${pattern.name}';
}

/// Extensions on [Note] for fluent scale building.
extension NoteScaleExtension on Note {
  /// Builds a [Scale] with this note as root using [pattern].
  Scale scale(ScalePattern pattern) => Scale(this, pattern);

  /// Major scale starting at this note.
  Scale get major => .major(this);

  /// Natural minor scale starting at this note.
  Scale get minor => .minor(this);

  /// Dorian scale starting at this note.
  Scale get dorian => .dorian(this);

  /// Phrygian scale starting at this note.
  Scale get phrygian => .phrygian(this);

  /// Lydian scale starting at this note.
  Scale get lydian => .lydian(this);

  /// Mixolydian scale starting at this note.
  Scale get mixolydian => .mixolydian(this);

  /// Minor pentatonic scale starting at this note.
  Scale get minorPentatonic => .minorPentatonic(this);

  /// Major pentatonic scale starting at this note.
  Scale get majorPentatonic => .majorPentatonic(this);

  /// Blues scale starting at this note.
  Scale get blues => .blues(this);
}
