/// A musical time signature represented as (numerator, denominator), e.g. (4, 4) or (3, 4).
typedef TimeSignature = (int numerator, int denominator);

/// Common note division values.
enum NoteValue {
  whole,
  half,
  quarter,
  eighth,
  sixteenth,
  thirtySecond,
}

/// Represents musical tempo and metrical timing.
///
/// Converts musical time (bars, beats, note divisions) into physical units
/// (seconds, samples, audio pipeline blocks, and frequency in Hertz).
class const Tempo(
  final double bpm, [
  final TimeSignature timeSignature = (4, 4),
]) {
  /// The duration of a quarter note (standard beat) in seconds.
  double get beat => 60.0 / bpm;

  /// The duration of a quarter note in seconds.
  double get quarter => beat;

  /// The duration of a whole note (4 quarter notes) in seconds.
  double get whole => quarter * 4.0;

  /// The duration of a half note (2 quarter notes) in seconds.
  double get half => quarter * 2.0;

  /// The duration of an eighth note in seconds.
  double get eighth => quarter * 0.5;

  /// The duration of a sixteenth note in seconds.
  double get sixteenth => quarter * 0.25;

  /// The duration of a thirty-second note in seconds.
  double get thirtySecond => quarter * 0.125;

  /// The duration of a full bar (measure) in seconds based on [timeSignature].
  ///
  /// For 4/4 time: 4 quarter notes.
  /// For 3/4 time: 3 quarter notes.
  /// For 6/8 time: 6 eighth notes.
  double get bar => whole * (timeSignature.$1 / timeSignature.$2);

  // --- Common Dotted Durations (duration * 1.5) ---

  /// Dotted half note in seconds.
  double get dottedHalf => half * 1.5;

  /// Dotted quarter note in seconds.
  double get dottedQuarter => quarter * 1.5;

  /// Dotted eighth note in seconds (classic rhythmic delay division).
  double get dottedEighth => eighth * 1.5;

  /// Dotted sixteenth note in seconds.
  double get dottedSixteenth => sixteenth * 1.5;

  // --- Common Triplet Durations (3 notes in the time of 2) ---

  /// Triplet half note in seconds.
  double get tripletHalf => half * (2.0 / 3.0);

  /// Triplet quarter note in seconds.
  double get tripletQuarter => quarter * (2.0 / 3.0);

  /// Triplet eighth note in seconds.
  double get tripletEighth => eighth * (2.0 / 3.0);

  /// Triplet sixteenth note in seconds.
  double get tripletSixteenth => sixteenth * (2.0 / 3.0);

  /// Calculates the duration in seconds for a given [NoteValue].
  double durationOf(
    NoteValue value, {
    bool dotted = false,
    bool triplet = false,
  }) {
    final base = switch (value) {
      .whole => whole,
      .half => half,
      .quarter => quarter,
      .eighth => eighth,
      .sixteenth => sixteenth,
      .thirtySecond => thirtySecond,
    };

    if (dotted) return base * 1.5;
    if (triplet) return base * (2.0 / 3.0);
    return base;
  }

  /// Calculates the frequency in Hertz for a given [NoteValue].
  ///
  /// Ideal for synchronizing LFOs, Clocks, or periodic modulators to the beat.
  double frequencyOf(
    NoteValue value, {
    bool dotted = false,
    bool triplet = false,
  }) {
    return 1.0 / durationOf(value, dotted: dotted, triplet: triplet);
  }

  /// Calculates the total number of audio samples for a given duration of bars and beats.
  int samplesFor({
    double bars = 0.0,
    double beats = 0.0,
    required int sampleRate,
  }) {
    final totalSeconds = (bars * bar) + (beats * beat);
    return (totalSeconds * sampleRate).round();
  }

  /// Calculates the number of audio pipeline processing blocks for a given duration
  /// of bars and beats.
  int blocksFor({
    double bars = 0.0,
    double beats = 0.0,
    required int sampleRate,
    required int vectorSize,
  }) {
    final totalSamples = samplesFor(
      bars: bars,
      beats: beats,
      sampleRate: sampleRate,
    );
    return (totalSamples / vectorSize).ceil();
  }
}
