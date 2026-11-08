import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:hum/hum.dart';

/// A function that builds an audio graph for a demo.
///
/// Can return a [TerminalNode] (such as [Out] or [WavSink]), an [AudioNode],
/// an [Outlet], or a `List<Outlet>`.
typedef DemoBuilder = Object Function(ProcessContext context, Tempo tempo);

/// Supported real-time audio playback engines.
/// Auto checks what you have in path.
enum AudioPlayerMode { auto, ffplay, sox }

/// Parsed CLI configuration for demo execution.
class const DemoOptions({
  final bool play = false,
  final AudioPlayerMode player = .auto,
  final bool offline = false,
  final String? outputPath,
  final int? bars,
  final double? bpm,
  final int? sampleRate,
  final int? vectorSize,
  final bool help = false,
}) {
  /// Parses CLI arguments using [ArgParser].
  factory parse(
    List<String> args, {
    required String name,
    required int defaultBars,
    required double defaultBpm,
    required int defaultSr,
    required int defaultVs,
    String? description,
  }) {
    final parser = ArgParser()
      ..addFlag(
        'play',
        abbr: 'p',
        negatable: false,
        help: 'Stream real-time audio (auto-detects ffplay or sox)',
      )
      ..addFlag('ffplay', negatable: false, help: 'Stream audio using ffplay')
      ..addFlag('sox', negatable: false, help: 'Stream audio using play (SoX)')
      ..addFlag(
        'offline',
        negatable: false,
        help: 'Bounce audio offline to WAV (default)',
      )
      ..addOption(
        'out',
        abbr: 'o',
        help: 'WAV output file path',
        defaultsTo: 'tmp/$name.wav',
      )
      ..addOption(
        'bars',
        abbr: 'b',
        help: 'Number of bars to play/render',
        defaultsTo: '$defaultBars',
      )
      ..addOption(
        'bpm',
        help: 'Playback tempo in BPM',
        defaultsTo: '${defaultBpm.round()}',
      )
      ..addOption(
        'sr',
        help: 'Audio sample rate in Hz',
        defaultsTo: '$defaultSr',
      )
      ..addOption(
        'vs',
        help: 'Audio vector/block size',
        defaultsTo: '$defaultVs',
      )
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Show this help information',
      );

    final ArgResults results;
    try {
      results = parser.parse(args);
    } on FormatException catch (e) {
      stderr.writeln('Error: ${e.message}\n');
      stderr.writeln(parser.usage);
      exitCode = 64;
      return const .parseResult(help: true);
    }

    if (results.flag('help')) {
      stdout.writeln('=== hum Audio Demo: $name ===');
      if (description != null && description.isNotEmpty) {
        stdout.writeln('$description\n');
      }
      stdout.writeln('Usage: dart run <demo_script>.dart [options]\n');
      stdout.writeln('Options:');
      stdout.writeln(parser.usage);
      return const .parseResult(help: true);
    }

    final hasFfplay = results.flag('ffplay');
    final hasSox = results.flag('sox');
    final hasPlay = results.flag('play') || hasFfplay || hasSox;
    final isOffline = results.flag('offline') || !hasPlay;

    final AudioPlayerMode playerMode = switch ((hasFfplay, hasSox)) {
      (true, _) => .ffplay,
      (_, true) => .sox,
      _ => .auto,
    };

    return DemoOptions(
      play: hasPlay && !results.flag('offline'),
      player: playerMode,
      offline: isOffline,
      outputPath: results.option('out'),
      bars: int.tryParse(results.option('bars') ?? ''),
      bpm: double.tryParse(results.option('bpm') ?? ''),
      sampleRate: int.tryParse(results.option('sr') ?? ''),
      vectorSize: int.tryParse(results.option('vs') ?? ''),
      help: false,
    );
  }

  const new parseResult({bool help = false}) : this(help: help);
}

/// Runs a hum audio graph demo with unified CLI flags, real-time audio playback,
/// and offline WAV bouncing.
Future<void> runDemo({
  required String name,
  required DemoBuilder builder,
  Tempo tempo = const Tempo(120),
  int bars = 4,
  int sampleRate = 44100,
  int vectorSize = 64,
  List<String> args = const [],
  String? description,
}) async {
  final options = DemoOptions.parse(
    args,
    name: name,
    defaultBars: bars,
    defaultBpm: tempo.bpm,
    defaultSr: sampleRate,
    defaultVs: vectorSize,
    description: description,
  );

  if (options.help) return;

  final effectiveBpm = options.bpm ?? tempo.bpm;
  final effectiveTempo = Tempo(effectiveBpm, tempo.timeSignature);
  final effectiveBars = options.bars ?? bars;
  final effectiveSr = options.sampleRate ?? sampleRate;
  final effectiveVs = options.vectorSize ?? vectorSize;
  final outputPath = options.outputPath ?? 'tmp/$name.wav';

  final context = ProcessContext(
    sampleRate: effectiveSr,
    vectorSize: effectiveVs,
  );

  final rawResult = builder(context, effectiveTempo);
  final terminal = _resolveTerminal(rawResult);

  if (options.play) {
    await _runLivePlayback(
      name: name,
      terminal: terminal,
      tempo: effectiveTempo,
      bars: effectiveBars,
      sampleRate: effectiveSr,
      vectorSize: effectiveVs,
      playerMode: options.player,
    );
  } else {
    _runOfflineBounce(
      name: name,
      terminal: terminal,
      context: context,
      tempo: effectiveTempo,
      bars: effectiveBars,
      sampleRate: effectiveSr,
      vectorSize: effectiveVs,
      outputPath: outputPath,
    );
  }
}

/// Resolves user's return value into a canonical [TerminalNode] using pattern matching.
TerminalNode _resolveTerminal(Object result) => switch (result) {
  final TerminalNode node => node,
  final Outlet outlet => Out.stereo(left: outlet, right: outlet),
  final List<Outlet> list when list.length == 1 => Out.stereo(
    left: list[0],
    right: list[0],
  ),
  final List<Outlet> list when list.length == 2 => Out.stereo(
    left: list[0],
    right: list[1],
  ),
  final List<Outlet> list when list.isNotEmpty => Out(channels: list),
  final AudioNode node when node.outlets.length == 1 => Out.stereo(
    left: node.outlets.first,
    right: node.outlets.first,
  ),
  final AudioNode node when node.outlets.length == 2 => Out.stereo(
    left: node.outlets[0],
    right: node.outlets[1],
  ),
  final AudioNode node when node.outlets.isNotEmpty => Out(
    channels: node.outlets,
  ),
  _ => throw ArgumentError(
    'Demo builder must return a TerminalNode, AudioNode, Outlet, or List<Outlet>. '
    'Received: ${result.runtimeType}',
  ),
};

/// Extracts output channels for file export using pattern matching.
List<Outlet> _extractOutlets(AudioNode node) => switch (node) {
  Out(:final channels) => channels,
  TerminalNode(:final inlets) => [for (final i in inlets) ?i.source],
  AudioNode(:final outlets) when outlets.isNotEmpty => outlets,
  AudioNode(:final inlets) => [for (final i in inlets) ?i.source],
};

/// Executes offline bouncing directly to a WAV file.
void _runOfflineBounce({
  required String name,
  required TerminalNode terminal,
  required ProcessContext context,
  required Tempo tempo,
  required int bars,
  required int sampleRate,
  required int vectorSize,
  required String outputPath,
}) {
  final file = File(outputPath);
  file.parent.createSync(recursive: true);

  final channels = _extractOutlets(terminal);
  final wav = WavSink.file(channels: channels, path: outputPath);

  final compileResult = compilePipeline(root: wav, context: context);
  if (compileResult.hasErrors) {
    stderr.writeln('❌ Graph compilation failed:');
    for (final diag in compileResult.diagnostics) {
      stderr.writeln('   $diag');
    }
    exitCode = 1;
    return;
  }

  final pipeline = compileResult.pipeline!;
  final totalBlocks = tempo.blocksFor(
    bars: bars.toDouble(),
    sampleRate: sampleRate,
    vectorSize: vectorSize,
  );
  final durationSec = (tempo.bar * bars).toStringAsFixed(1);

  stdout.writeln(
    '🎵 [hum] Bouncing $bars bars of "$name" ($durationSec s at ${tempo.bpm.toStringAsFixed(0)} BPM)...',
  );

  final stopwatch = Stopwatch()..start();
  for (int i = 0; i < totalBlocks; i++) {
    pipeline.process();
  }
  stopwatch.stop();

  pipeline.processorOf(wav).close();

  final fileBytes = file.existsSync() ? file.lengthSync() : 0;
  final sizeMb = (fileBytes / (1024 * 1024)).toStringAsFixed(2);
  final elapsedMs = stopwatch.elapsedMilliseconds;
  final speedFactor = (double.parse(durationSec) / (elapsedMs / 1000.0))
      .toStringAsFixed(1);

  stdout.writeln(
    '✅ [hum] Rendered to $outputPath ($sizeMb MB in ${elapsedMs}ms, ${speedFactor}x real-time)',
  );
  stdout.writeln('   To play: ffplay -autoexit -nodisp $outputPath');
  stdout.writeln('   Or run:  dart run <script> --play');
}

/// Executes real-time live playback via piped subprocess audio.
Future<void> _runLivePlayback({
  required String name,
  required TerminalNode terminal,
  required Tempo tempo,
  required int bars,
  required int sampleRate,
  required int vectorSize,
  required AudioPlayerMode playerMode,
}) async {
  final numChannels = terminal.inlets.length;
  PipedAudioOutput? output;
  AudioHost? host;
  StreamSubscription? sigintSub;

  try {
    output = await _resolvePlayer(
      mode: playerMode,
      numChannels: numChannels,
      vectorSize: vectorSize,
      sampleRate: sampleRate,
    );

    host = await AudioHost.spawn(
      context: ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      ),
    );

    final diagnostics = host.setGraph(root: terminal);
    if (diagnostics.isNotEmpty) {
      stderr.writeln('❌ Graph compilation failed:');
      for (final diag in diagnostics) {
        stderr.writeln('   $diag');
      }
      exitCode = 1;
      return;
    }

    final durationSeconds = tempo.bar * bars;
    stdout.writeln(
      '🔊 [hum] Playing $bars bars of "$name" (${tempo.bpm.toStringAsFixed(0)} BPM) via ${output.process != null ? 'subprocess' : 'audio output'}...',
    );
    stdout.writeln('   Press Ctrl+C to abort playback.');

    final completer = Completer<void>();

    sigintSub = ProcessSignal.sigint.watch().listen((_) {
      stdout.writeln('\n⏹️  [hum] Playback interrupted by user.');
      if (!completer.isCompleted) completer.complete();
    });

    await host.startPlayback(output);

    final stopwatch = Stopwatch()..start();
    final timer = Timer.periodic(const Duration(milliseconds: 250), (t) {
      final elapsed = stopwatch.elapsedMilliseconds / 1000.0;
      final currentBar = ((elapsed / tempo.bar) + 1).floor().clamp(1, bars);
      stdout.write(
        '\r   Playing: Bar $currentBar / $bars [${(elapsed).toStringAsFixed(1)}s / ${(durationSeconds).toStringAsFixed(1)}s]',
      );

      if (elapsed >= durationSeconds) {
        t.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });

    await completer.future;
    timer.cancel();
    stdout.writeln('\n✨ [hum] Playback complete.');
  } finally {
    await sigintSub?.cancel();
    if (host != null) {
      await host.stopPlayback();
      await host.dispose();
    }
    if (output != null) {
      await output.close();
    }
  }
}

/// Resolves audio subprocess player using pattern matching.
Future<PipedAudioOutput> _resolvePlayer({
  required AudioPlayerMode mode,
  required int numChannels,
  required int vectorSize,
  required int sampleRate,
}) async => switch (mode) {
  .ffplay => .ffplay(
    numChannels: numChannels,
    vectorSize: vectorSize,
    sampleRate: sampleRate,
  ),
  .sox => .sox(
    numChannels: numChannels,
    vectorSize: vectorSize,
    sampleRate: sampleRate,
  ),
  .auto => switch (await _hasExecutable('ffplay')) {
    true => .ffplay(
      numChannels: numChannels,
      vectorSize: vectorSize,
      sampleRate: sampleRate,
    ),
    false => switch (await _hasExecutable('play')) {
      true => .sox(
        numChannels: numChannels,
        vectorSize: vectorSize,
        sampleRate: sampleRate,
      ),
      false => throw StateError(
        'No supported real-time audio player found on PATH (checked "ffplay" and "play" [SoX]).\n'
        'Please install ffmpeg (for ffplay) or sox, or run without --play to bounce a WAV file.',
      ),
    },
  },
};

/// Checks if an executable exists on the system PATH.
Future<bool> _hasExecutable(String executable) async {
  try {
    final cmd = Platform.isWindows ? 'where' : 'which';
    final result = await Process.run(cmd, [executable]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
