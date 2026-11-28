// Simple guitar tuner.

// You need SoX installed with `sox` or ffmpeg installed with `ffmpeg` in path.

import 'dart:async';
import 'dart:io' show exit, stderr, stdin, stdout;

import 'package:args/args.dart';
import 'package:hum/hum.dart';
import 'package:hum/io.dart';

import '../harness.dart' show hasExecutable;

final parser = ArgParser()
  ..addOption(
    'input',
    abbr: 'i',
    allowed: ['auto', 'sox', 'ffmpeg'],
    defaultsTo: 'auto',
    help: 'Audio input backend (auto prefers sox, falls back to ffmpeg)',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Show help message',
  );

final _pitchSmoother = _PitchSmoother(
  holdDuration: const Duration(milliseconds: 400),
  alpha: 0.25,
);
AutocorrelationReading? _autocorrReading;
MeterReading? _meterReading;
double _rawClarity = 0.0;

void main(List<String> args) async {
  final results = parser.parse(args);

  if (results['help'] == true) {
    stdout.writeln('Interactive Guitar Tuner');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final inputMode = results.option('input')!;
  final sr = 44100, vs = 64;

  final SubprocessSource source;
  switch (inputMode) {
    case 'sox':
      source = SubprocessSource.sox(sampleRate: sr);
    case 'ffmpeg':
      // TODO: figure out why ffmpeg isn't working well
      source = SubprocessSource.ffmpeg(sampleRate: sr, input: ':0');
    default:
      if (await hasExecutable('sox')) {
        source = SubprocessSource.sox(sampleRate: sr);
      } else if (await hasExecutable('ffmpeg')) {
        source = SubprocessSource.ffmpeg(sampleRate: sr, input: ':0');
      } else {
        stderr.writeln(
          'No supported audio capture tool found on PATH (checked "sox" and "ffmpeg").\n'
          'Please install sox or ffmpeg.',
        );
        exit(1);
      }
  }

  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final host = await IsolateAudioHost.spawn(context: context);

  // Band-limit mic input (70 Hz – 1000 Hz) to strip room rumble, DC offset,
  // and high-frequency pick/air noise before pitch detection.
  final hpf = SvfFilter(
    input: source.outlet,
    cutoff: const .value(70.0),
  ).highpass;
  final lpf = SvfFilter(
    input: hpf,
    cutoff: const .value(1000.0),
  ).lowpass;

  final meter = Meter.mono(input: lpf);

  final yin = PitchDetector(
    input: meter.outlet,
    minRms: (-60).db,
    windowSize: 1024,
    hopSize: 256,
    minFrequency: 70.0,
    maxFrequency: 600.0,
    threshold: 0.15,
  );
  final autocorrelation = Autocorrelation(input: yin.audio);
  final out = Out.mono(autocorrelation.outlet);

  final diagnostics = host.setGraph(root: out);

  if (diagnostics.isNotEmpty) {
    for (final d in diagnostics) {
      stdout.writeln(d);
    }
    exit(1);
  }

  final meterTelemetry = host.telemetryOf(meter)!;
  final yinTelemetry = host.telemetryOf(yin)!;
  final autocorrTelemetry = host.telemetryOf(autocorrelation)!;

  meterTelemetry.stream.listen((reading) => _meterReading = reading);
  yinTelemetry.stream.listen((reading) {
    _rawClarity = reading.clarity;
    _pitchSmoother.add(reading);
  });
  autocorrTelemetry.stream.listen((reading) => _autocorrReading = reading);

  // Start playback with no input (because it's using subprocess)
  // and no output because it's a no output graph.
  await host.startPlayback();

  final oldLineMode = stdin.lineMode;
  final oldEchoMode = stdin.echoMode;
  stdin.lineMode = false;
  stdin.echoMode = false;
  stdout.write('\x1b[?1049h\x1b[?25l');

  final completer = Completer<void>();

  void render() {
    final buf = StringBuffer();
    buf.write('\x1b[H'); // Move cursor to top-left (1, 1)

    void line(String text) =>
        buf.writeln('$text\x1b[K'); // Clear line to the right

    final pitch = _pitchSmoother.current();

    line('  Tuner');
    line('');
    if (pitch != null) {
      final sign = pitch.cents >= 0 ? '+' : '';
      final status = pitch.isLive ? '' : ' (held)';
      line('  Frequency: ${pitch.frequency.toStringAsFixed(2)} Hz$status');
      line('  Note:      ${pitch.note.name}');
      line('  Cents:     $sign${pitch.cents.toStringAsFixed(1)} c');
      line('  Clarity:   ${(pitch.clarity * 100).toStringAsFixed(0)}%');
    } else {
      line('  Frequency: --');
      line('  Note:      --');
      line('  Cents:     --');
      line('  Clarity:   ${(_rawClarity * 100).toStringAsFixed(0)}%');
    }
    line('');
    final rmsDb = _meterReading?.rmsDb ?? -120.0;
    final peakDb = _meterReading?.peakDb ?? -120.0;
    line(
      '  Level:     RMS ${rmsDb.toStringAsFixed(1)} dB  (Peak ${peakDb.toStringAsFixed(1)} dB)',
    );
    line(
      '  Autocorrelation: ${_autocorrReading?.frequency.toStringAsFixed(2) ?? '--'} Hz',
    );

    stdout.write(buf.toString());
  }

  void handleInput(List<int> codeUnits) {
    if (completer.isCompleted) return;
    switch (codeUnits) {
      case [113] || [81]: // q/Q: exit
        completer.complete();
        return;
    }
  }

  render();
  final stdinSub = stdin.listen(handleInput);
  final renderTimer = Timer.periodic(
    const Duration(milliseconds: 50),
    (_) => render(),
  );

  try {
    await completer.future;
  } finally {
    renderTimer.cancel();
    await stdinSub.cancel();
    await host.stopPlayback();
    await host.dispose();
    stdin.lineMode = oldLineMode;
    stdin.echoMode = oldEchoMode;
    stdout.write('\x1b[?25h\x1b[?1049l\nBye bye!\n');
    exit(0);
  }
}

/// Holds and smooths raw [PitchReading]s for steady tuner display:
/// - 3-sample median filter on frequency to reject single-hop octave glitches
/// - EMA smoothing on frequency/cents (snapping immediately on note change)
/// - Short hold window across brief unpitched dropouts before clearing
class _PitchSmoother({
  final Duration holdDuration = const Duration(milliseconds: 400),
  final double alpha = 0.25,
}) {
  final List<double> _recentHz = [];
  DateTime? _lastPitchAt;
  double? _smoothedHz;
  double? _smoothedCents;
  double _clarity = 0.0;
  Note? _note;
  bool _live = false;

  void add(PitchReading reading, [DateTime? now]) {
    final timestamp = now ?? DateTime.now();
    if (!reading.hasPitch) {
      _live = false;
      _clarity = reading.clarity;
      return;
    }

    _lastPitchAt = timestamp;
    _live = true;
    _clarity = reading.clarity;

    _recentHz.add(reading.frequency);
    if (_recentHz.length > 3) _recentHz.removeAt(0);
    final medianHz = _median(_recentHz);

    final midi = hzToMidi(medianHz, reading.a4);
    final rounded = midi.round();
    final cents = (midi - rounded) * 100.0;

    if (_note?.midi != rounded || _smoothedHz == null) {
      // Snap immediately when switching notes.
      _note = Note(rounded, reading.a4);
      _smoothedHz = medianHz;
      _smoothedCents = cents;
    } else {
      _smoothedHz = _smoothedHz! * (1.0 - alpha) + medianHz * alpha;
      _smoothedCents = _smoothedCents! * (1.0 - alpha) + cents * alpha;
    }
  }

  /// Returns the current smoothed display snapshot, or `null` once the hold
  /// window expires.
  ({
    double frequency,
    Note note,
    double cents,
    double clarity,
    bool isLive,
  })?
  current([DateTime? now]) {
    final lastAt = _lastPitchAt;
    if (lastAt == null || _note == null || _smoothedHz == null) return null;

    final timestamp = now ?? DateTime.now();
    if (timestamp.difference(lastAt) > holdDuration) {
      _reset();
      return null;
    }

    return (
      frequency: _smoothedHz!,
      note: _note!,
      cents: _smoothedCents!,
      clarity: _clarity,
      isLive: _live,
    );
  }

  void _reset() {
    _recentHz.clear();
    _lastPitchAt = null;
    _smoothedHz = null;
    _smoothedCents = null;
    _note = null;
    _live = false;
  }

  static double _median(List<double> values) {
    if (values.length == 1) return values[0];
    if (values.length == 2) return (values[0] + values[1]) * 0.5;

    final a = values[0], b = values[1], c = values[2];

    if ((a >= b && a <= c) || (a <= b && a >= c)) return a;
    if ((b >= a && b <= c) || (b <= a && b >= c)) return b;

    return c;
  }
}
