import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:hum/hum.dart';
import 'package:hum/io.dart';

/// A function that builds an audio graph for a demo.
///
/// Can return a [TerminalNode] (such as [Out] or [WavSink]), an [AudioNode],
/// an [Outlet], or a `List<Outlet>`.
typedef DemoBuilder = Object Function(
  ProcessContext context,
  Tempo tempo,
  ArgResults args,
);

/// Lightweight buffer/wavetable registry for demos that use [SamplePlayer] or
/// [WavetableOscillator] with [runDemo].
///
/// Pre-allocated handles are loaded automatically into the underlying
/// [AudioHost] (for `--play`) or [AudioPipeline] (for `--offline` / `--bench`).
class DemoBuffers {
  final Map<BufferId, AudioBuffer> _buffers = {};
  int _nextId = 1;

  /// Registers [buffer] and returns a [BufferHandle] usable in demo graphs.
  BufferHandle loadBuffer(AudioBuffer buffer) {
    final id = BufferId(_nextId++);
    _buffers[id] = buffer;
    return BufferHandle(
      id: id,
      sampleRate: buffer.sampleRate,
      numChannels: buffer.numChannels,
      length: buffer.length,
    );
  }

  /// Registers [table] and returns a [WavetableHandle] usable in demo graphs.
  WavetableHandle loadWavetable(Wavetable table) {
    final handle = loadBuffer(table.toAudioBuffer());
    return WavetableHandle(
      buffer: handle,
      frameSize: table.frameSize,
      numFrames: table.numFrames,
      mipmapped: table.mipmapped,
    );
  }

  Map<BufferId, AudioBuffer> get _all => _buffers;
}

/// Supported real-time audio playback engines.
/// Auto checks what you have in path.
enum AudioPlayerMode { auto, ffplay, sox }

/// Parsed CLI configuration for demo execution.
class const DemoOptions({
  final bool play = false,
  final AudioPlayerMode player = .auto,
  final bool offline = false,
  final bool analyse = false,
  final bool json = false,
  final bool bench = false,
  final bool benchWorker = false,
  final bool verboseGc = false,
  final bool graph = false,
  final String? outputPath,
  final int? bars,
  final double? bpm,
  final int? sampleRate,
  final int? vectorSize,
  final bool help = false,
  final ArgResults? rawArgs,
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
    void Function(ArgParser parser)? configureArgs,
  }) {
    final parser = ArgParser()
      ..addFlag(
        'play',
        abbr: 'p',
        negatable: false,
        help: 'Stream real-time audio (auto-detects sox or ffplay)',
      )
      ..addFlag('ffplay', negatable: false, help: 'Stream audio using ffplay')
      ..addFlag('sox', negatable: false, help: 'Stream audio using play (SoX)')
      ..addFlag(
        'offline',
        negatable: false,
        help: 'Bounce audio offline to WAV (default)',
      )
      ..addFlag(
        'analyse',
        abbr: 'a',
        negatable: false,
        help:
            'Analyse signal levels, clipping, spectral balance, and bar dynamics (standalone or with --offline)',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Format --analyse report as JSON (implies --analyse)',
      )
      ..addFlag(
        'bench',
        abbr: 'B',
        negatable: false,
        help: 'Benchmark throughput, block latency, and GC allocation profile',
      )
      ..addFlag(
        'bench-worker',
        hide: true,
        negatable: false,
        help: 'Internal worker flag for GC profiling',
      )
      ..addFlag(
        'verbose-gc',
        abbr: 'v',
        negatable: false,
        help: 'Print raw GC scavenge event logs during benchmark',
      )
      ..addFlag(
        'graph',
        abbr: 'g',
        negatable: false,
        help: 'Print an ASCII visualization of the compiled audio graph',
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

    configureArgs?.call(parser);

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

    final isBench = results.flag('bench') || results.flag('bench-worker');
    final isWorker = results.flag('bench-worker');
    final hasGraph = results.flag('graph');
    final isJson = results.flag('json');
    final hasAnalyse = results.flag('analyse') || isJson;
    final hasFfplay = results.flag('ffplay');
    final hasSox = results.flag('sox');
    final hasPlay = results.flag('play') || hasFfplay || hasSox;
    final isOffline =
        results.flag('offline') ||
        (!hasPlay && !isBench && !hasGraph && !hasAnalyse);

    final AudioPlayerMode playerMode = switch ((hasFfplay, hasSox)) {
      (true, _) => .ffplay,
      (_, true) => .sox,
      _ => .auto,
    };

    return DemoOptions(
      play:
          hasPlay &&
          !results.flag('offline') &&
          !isBench &&
          !hasGraph &&
          !hasAnalyse,
      player: playerMode,
      offline: isOffline,
      analyse: hasAnalyse,
      json: isJson,
      bench: isBench,
      benchWorker: isWorker,
      verboseGc: results.flag('verbose-gc'),
      graph: hasGraph,
      outputPath: results.option('out'),
      bars: int.tryParse(results.option('bars') ?? ''),
      bpm: double.tryParse(results.option('bpm') ?? ''),
      sampleRate: int.tryParse(results.option('sr') ?? ''),
      vectorSize: int.tryParse(results.option('vs') ?? ''),
      help: false,
      rawArgs: results,
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
  void Function(ArgParser parser)? configureArgs,
  DemoBuffers? buffers,
}) async {
  final options = DemoOptions.parse(
    args,
    name: name,
    defaultBars: bars,
    defaultBpm: tempo.bpm,
    defaultSr: sampleRate,
    defaultVs: vectorSize,
    description: description,
    configureArgs: configureArgs,
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

  final rawResult = builder(context, effectiveTempo, options.rawArgs!);
  final terminal = _resolveTerminal(rawResult);

  final demoBuffers = buffers?._all;

  if (options.graph) {
    stdout.writeln(formatGraphAscii(root: terminal, title: name));
    return;
  }

  if (options.bench) {
    await _runBenchmark(
      name: name,
      terminal: terminal,
      context: context,
      tempo: effectiveTempo,
      bars: effectiveBars,
      sampleRate: effectiveSr,
      vectorSize: effectiveVs,
      isWorker: options.benchWorker,
      verboseGc: options.verboseGc,
      args: args,
      buffers: demoBuffers,
    );
  } else if (options.play) {
    await _runLivePlayback(
      name: name,
      terminal: terminal,
      tempo: effectiveTempo,
      bars: effectiveBars,
      sampleRate: effectiveSr,
      vectorSize: effectiveVs,
      playerMode: options.player,
      buffers: demoBuffers,
    );
  } else if (options.analyse && !options.offline) {
    _runAnalyse(
      name: name,
      terminal: terminal,
      context: context,
      tempo: effectiveTempo,
      bars: effectiveBars,
      sampleRate: effectiveSr,
      vectorSize: effectiveVs,
      jsonOutput: options.json,
      buffers: demoBuffers,
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
      analyse: options.analyse,
      jsonOutput: options.json,
      buffers: demoBuffers,
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

/// Executes offline bouncing directly to a WAV file, optionally running signal
/// analysis in the same pass.
void _runOfflineBounce({
  required String name,
  required TerminalNode terminal,
  required ProcessContext context,
  required Tempo tempo,
  required int bars,
  required int sampleRate,
  required int vectorSize,
  required String outputPath,
  bool analyse = false,
  bool jsonOutput = false,
  Map<BufferId, AudioBuffer>? buffers,
}) {
  final file = File(outputPath);
  file.parent.createSync(recursive: true);

  final channels = _extractOutlets(terminal);
  final wav = WavSink.file(channels: channels, path: outputPath);

  final compileResult = compilePipeline(
    root: wav,
    context: context,
    buffers: buffers,
  );
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

  final analyser = analyse
      ? _AudioAnalyser(
          numChannels: pipeline.numChannels,
          sampleRate: sampleRate,
          bars: bars,
          samplesPerBar: (tempo.bar * sampleRate).round().clamp(1, 1 << 30),
        )
      : null;

  if (!jsonOutput) {
    stdout.writeln(
      '🎵 [hum] Bouncing $bars bars of "$name" ($durationSec s at ${tempo.bpm.toStringAsFixed(0)} BPM)...',
    );
  }

  final stopwatch = Stopwatch()..start();
  if (analyser != null) {
    for (int i = 0; i < totalBlocks; i++) {
      pipeline.process();
      analyser.feed(pipeline.outputs);
    }
  } else {
    for (int i = 0; i < totalBlocks; i++) {
      pipeline.process();
    }
  }
  stopwatch.stop();

  pipeline.processorOf(wav).close();

  final fileBytes = file.existsSync() ? file.lengthSync() : 0;
  final sizeMb = (fileBytes / (1024 * 1024)).toStringAsFixed(2);
  final elapsedMs = stopwatch.elapsedMilliseconds;
  final speedFactor = (double.parse(durationSec) / (elapsedMs / 1000.0))
      .toStringAsFixed(1);

  if (!jsonOutput) {
    stdout.writeln(
      '✅ [hum] Rendered to $outputPath ($sizeMb MB in ${elapsedMs}ms, ${speedFactor}x real-time)',
    );
    stdout.writeln('   To play: ffplay -autoexit -nodisp $outputPath');
    stdout.writeln('   Or run:  dart run <script> --play');
  }

  if (analyser != null) {
    _emitAnalysisReport(
      analyser: analyser,
      name: name,
      tempo: tempo,
      bars: bars,
      sampleRate: sampleRate,
      vectorSize: vectorSize,
      elapsedMs: elapsedMs,
      outputPath: outputPath,
      jsonOutput: jsonOutput,
    );
  }
}

/// Executes standalone in-memory signal analysis without writing a WAV file.
void _runAnalyse({
  required String name,
  required TerminalNode terminal,
  required ProcessContext context,
  required Tempo tempo,
  required int bars,
  required int sampleRate,
  required int vectorSize,
  required bool jsonOutput,
  Map<BufferId, AudioBuffer>? buffers,
}) {
  final compileResult = compilePipeline(
    root: terminal,
    context: context,
    buffers: buffers,
  );
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

  final analyser = _AudioAnalyser(
    numChannels: pipeline.numChannels,
    sampleRate: sampleRate,
    bars: bars,
    samplesPerBar: (tempo.bar * sampleRate).round().clamp(1, 1 << 30),
  );

  final stopwatch = Stopwatch()..start();
  for (int i = 0; i < totalBlocks; i++) {
    pipeline.process();
    analyser.feed(pipeline.outputs);
  }
  stopwatch.stop();

  _emitAnalysisReport(
    analyser: analyser,
    name: name,
    tempo: tempo,
    bars: bars,
    sampleRate: sampleRate,
    vectorSize: vectorSize,
    elapsedMs: stopwatch.elapsedMilliseconds,
    jsonOutput: jsonOutput,
  );
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
  Map<BufferId, AudioBuffer>? buffers,
}) async {
  final numChannels = terminal.inlets.length;
  PipedAudioOutput? output;
  AudioHost? host;
  StreamSubscription? sigintSub;

  try {
    output = await resolvePlayer(
      mode: playerMode,
      numChannels: numChannels,
      vectorSize: vectorSize,
      sampleRate: sampleRate,
    );

    host = await IsolateAudioHost.spawn(
      context: ProcessContext(
        sampleRate: sampleRate,
        vectorSize: vectorSize,
      ),
    );

    if (buffers != null) {
      for (final buffer in buffers.values) {
        host.loadBuffer(buffer);
      }
    }

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
    final playerName = switch (output.executable) {
      'play' => 'sox',
      final exe? => exe,
      null => 'audio output',
    };
    stdout.writeln(
      '🔊 [hum] Playing $bars bars of "$name" (${tempo.bpm.toStringAsFixed(0)} BPM) via $playerName...',
    );
    stdout.writeln('   Press Ctrl+C to abort playback.');

    final completer = Completer<void>();

    sigintSub = ProcessSignal.sigint.watch().listen((_) {
      stdout.writeln('\n⏹️  [hum] Playback interrupted by user.');
      if (!completer.isCompleted) completer.complete();
    });

    await host.startPlayback(output: output);

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
  }
}

/// Resolves audio subprocess player using pattern matching.
Future<PipedAudioOutput> resolvePlayer({
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
  .auto => switch (await hasExecutable('play')) {
    true => .sox(
      numChannels: numChannels,
      vectorSize: vectorSize,
      sampleRate: sampleRate,
    ),
    false => switch (await hasExecutable('ffplay')) {
      true => .ffplay(
        numChannels: numChannels,
        vectorSize: vectorSize,
        sampleRate: sampleRate,
      ),
      false => throw StateError(
        'No supported real-time audio player found on PATH (checked "play" [SoX] and "ffplay").\n'
        'Please install sox or ffmpeg (for ffplay), or run without --play to bounce a WAV file.',
      ),
    },
  },
};

/// Checks if an executable exists on the system PATH.
Future<bool> hasExecutable(String executable) async {
  try {
    final cmd = Platform.isWindows ? 'where' : 'which';
    final result = await Process.run(cmd, [executable]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Executes a high-precision throughput, block latency, and GC allocation benchmark.
Future<void> _runBenchmark({
  required String name,
  required TerminalNode terminal,
  required ProcessContext context,
  required Tempo tempo,
  required int bars,
  required int sampleRate,
  required int vectorSize,
  required bool isWorker,
  bool verboseGc = false,
  required List<String> args,
  Map<BufferId, AudioBuffer>? buffers,
}) async {
  if (!isWorker) {
    // Parent process: try to spawn a worker process with --verbose_gc to capture exact allocation metrics
    final scriptUri = Platform.script;
    if (scriptUri.scheme == 'file' &&
        File(scriptUri.toFilePath()).existsSync()) {
      try {
        final forwardedVmFlags = [
          for (final flag in Platform.executableArguments)
            if (!flag.startsWith('--resolved_executable_name') &&
                !flag.startsWith('--executable_name') &&
                !flag.startsWith('--packages') &&
                flag != '--verbose_gc')
              flag,
        ];
        final packageConfigUri = await Isolate.packageConfig;
        final packageConfigPath =
            packageConfigUri != null && packageConfigUri.scheme == 'file'
            ? packageConfigUri.toFilePath()
            : '.dart_tool/package_config.json';
        final workerArgs = <String>[
          '--packages=$packageConfigPath',
          '--verbose_gc',
          ...forwardedVmFlags,
          scriptUri.toFilePath(),
          '--bench-worker',
          for (final a in args)
            if (a != '--bench' && a != '-B' && a != '--bench-worker') a,
        ];
        final result = await Process.run(Platform.executable, workerArgs);
        if (result.exitCode == 0) {
          _displayBenchmarkReport(
            name: name,
            tempo: tempo,
            bars: bars,
            sampleRate: sampleRate,
            vectorSize: vectorSize,
            stdoutText: result.stdout as String,
            stderrText: result.stderr as String,
            verboseGc: verboseGc,
          );
          return;
        }
      } catch (_) {
        // Fall back to in-process benchmark if spawning is blocked
      }
    }
  }

  // Worker or in-process execution
  final compileResult = compilePipeline(
    root: terminal,
    context: context,
    buffers: buffers,
  );
  if (compileResult.hasErrors) {
    stderr.writeln('❌ Graph compilation failed:');
    for (final diag in compileResult.diagnostics) {
      stderr.writeln('   $diag');
    }
    exitCode = 1;
    return;
  }

  final pipeline = compileResult.pipeline!;

  // 1. Warm-up phase: run 10,000 blocks to allow Dart VM JIT optimization & inlining
  const warmupBlocks = 25000;
  for (int i = 0; i < warmupBlocks; i++) {
    pipeline.process();
  }

  // 2. Steady-state benchmark
  final totalBlocks = tempo.blocksFor(
    bars: bars.toDouble(),
    sampleRate: sampleRate,
    vectorSize: vectorSize,
  );

  stderr.writeln('=== HUM_BENCHMARK_START ===');
  final stopwatch = Stopwatch()..start();
  for (int i = 0; i < totalBlocks; i++) {
    pipeline.process();
  }
  stopwatch.stop();
  stderr.writeln('=== HUM_BENCHMARK_END ===');

  final elapsedUs = stopwatch.elapsedMicroseconds;

  if (isWorker) {
    stdout.writeln('METRICS: $totalBlocks $elapsedUs');
  } else {
    _displayInProcessReport(
      name: name,
      tempo: tempo,
      bars: bars,
      sampleRate: sampleRate,
      vectorSize: vectorSize,
      totalBlocks: totalBlocks,
      elapsedUs: elapsedUs,
    );
  }
}

/// Formats and displays benchmark results with parsed GC metrics.
void _displayBenchmarkReport({
  required String name,
  required Tempo tempo,
  required int bars,
  required int sampleRate,
  required int vectorSize,
  required String stdoutText,
  required String stderrText,
  bool verboseGc = false,
}) {
  final match = RegExp(r'METRICS:\s*(\d+)\s+(\d+)').firstMatch(stdoutText);
  if (match == null) {
    stdout.write(stdoutText);
    stderr.write(stderrText);
    return;
  }

  final totalBlocks = int.parse(match.group(1)!);
  final elapsedUs = int.parse(match.group(2)!);

  int startupScavenges = 0;
  double startupMb = 0.0;
  int steadyScavenges = 0;
  double steadyMb = 0.0;
  final steadyPausesMs = <double>[];

  bool inBenchmark = false;
  for (final line in stderrText.split('\n')) {
    if (line.contains('=== HUM_BENCHMARK_START ===')) {
      inBenchmark = true;
      continue;
    }
    if (line.contains('=== HUM_BENCHMARK_END ===')) {
      inBenchmark = false;
      continue;
    }

    if (line.contains('Scavenge') || line.contains('MarkSweep')) {
      final parts = line.split(',');
      double pauseMs = 0.0;
      double mb = 0.0;
      if (parts.length > 4) {
        pauseMs = double.tryParse(parts[4].trim()) ?? 0.0;
      }
      if (parts.length > 5) {
        mb = double.tryParse(parts[5].trim()) ?? 0.0;
      }
      if (inBenchmark) {
        if (verboseGc) {
          stderr.writeln('STEADY GC: $line');
        }
        steadyScavenges++;
        steadyMb += mb;
        steadyPausesMs.add(pauseMs);
      } else {
        startupScavenges++;
        startupMb += mb;
      }
    }
  }

  final totalSamples = totalBlocks * vectorSize;
  final audioDurationSec = totalSamples / sampleRate;
  final renderTimeMs = elapsedUs / 1000.0;
  final speedFactor = (audioDurationSec * 1000000.0) / elapsedUs;
  final usPerBlock = elapsedUs / totalBlocks;
  final blockBudgetUs = (vectorSize / sampleRate) * 1000000.0;
  final dspLoadPct = (usPerBlock / blockBudgetUs) * 100.0;
  final mSamplesPerSec = totalSamples / (elapsedUs / 1000000.0) / 1000000.0;

  final border = '═' * 66;
  stdout.writeln('╔$border╗');
  stdout.writeln('║ ⚡ [hum] Audio Engine Benchmark: ${name.padRight(31)} ║');
  stdout.writeln('╠$border╣');
  stdout.writeln(
    '${'║ Duration:       ${audioDurationSec.toStringAsFixed(1)}s audio ($bars bars @ ${tempo.bpm.round()} BPM)'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ Sample Rate:    $sampleRate Hz | Vector Size: $vectorSize samples'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ Render Time:    ${renderTimeMs.toStringAsFixed(2)} ms ($totalBlocks blocks processed)'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ Throughput:     ${speedFactor.toStringAsFixed(0)}x real-time (${mSamplesPerSec.toStringAsFixed(2)} M samples/sec)'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ Block Latency:  ${usPerBlock.toStringAsFixed(2)} µs / block (budget: ${blockBudgetUs.toStringAsFixed(1)} µs)'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ DSP Load:       ${dspLoadPct.toStringAsFixed(3)}% of audio callback budget'.padRight(67)}║',
  );
  if (steadyScavenges == 0) {
    stdout.writeln(
      '${'║ Steady-State:   0 GC scavenges (ZERO heap allocations! ⚡)'.padRight(67)}║',
    );
  } else {
    stdout.writeln(
      '${'║ Steady-State:   ⚠️  $steadyScavenges GC scavenges (${steadyMb.toStringAsFixed(1)} MB garbage)'.padRight(67)}║',
    );
    final double steadyPauseTotalMs = steadyPausesMs.isEmpty
        ? 0.0
        : steadyPausesMs.reduce((a, b) => a + b);
    final double steadyPauseMinMs = steadyPausesMs.isEmpty
        ? 0.0
        : steadyPausesMs.reduce((a, b) => a < b ? a : b);
    final double steadyPauseMaxMs = steadyPausesMs.isEmpty
        ? 0.0
        : steadyPausesMs.reduce((a, b) => a > b ? a : b);
    final double steadyPauseAvgMs = steadyPausesMs.isEmpty
        ? 0.0
        : steadyPauseTotalMs / steadyPausesMs.length;

    final gcPct = renderTimeMs > 0
        ? (steadyPauseTotalMs / renderTimeMs) * 100.0
        : 0.0;
    final totalStr = steadyPauseTotalMs == 0.0
        ? '<0.1 ms'
        : '${steadyPauseTotalMs.toStringAsFixed(1)} ms';
    final pctStr = (steadyPauseTotalMs == 0.0 || gcPct < 0.01)
        ? '<0.01%'
        : '${gcPct.toStringAsFixed(2)}%';
    stdout.writeln(
      '${'║ GC Pause Time:  $totalStr total ($pctStr of render time)'.padRight(67)}║',
    );

    final minStr = '${steadyPauseMinMs.toStringAsFixed(1)} ms';
    final maxStr = '${steadyPauseMaxMs.toStringAsFixed(1)} ms';
    final avgStr = steadyPauseAvgMs < 0.01
        ? '<0.01 ms'
        : (steadyPauseAvgMs < 0.1
              ? '${steadyPauseAvgMs.toStringAsFixed(2)} ms'
              : '${steadyPauseAvgMs.toStringAsFixed(1)} ms');
    stdout.writeln(
      '${'║ Pause Duration: avg: $avgStr | min: $minStr | max: $maxStr'.padRight(67)}║',
    );
  }
  stdout.writeln(
    '${'║ JIT Warmup:     $startupScavenges scavenges (${startupMb.toStringAsFixed(1)} MB during compilation)'.padRight(67)}║',
  );
  stdout.writeln('╚$border╝');
}

/// Fallback display when subprocess execution is not available.
void _displayInProcessReport({
  required String name,
  required Tempo tempo,
  required int bars,
  required int sampleRate,
  required int vectorSize,
  required int totalBlocks,
  required int elapsedUs,
}) {
  final totalSamples = totalBlocks * vectorSize;
  final audioDurationSec = totalSamples / sampleRate;
  final renderTimeMs = elapsedUs / 1000.0;
  final speedFactor = (audioDurationSec * 1000000.0) / elapsedUs;
  final usPerBlock = elapsedUs / totalBlocks;
  final blockBudgetUs = (vectorSize / sampleRate) * 1000000.0;
  final dspLoadPct = (usPerBlock / blockBudgetUs) * 100.0;
  final mSamplesPerSec = totalSamples / (elapsedUs / 1000000.0) / 1000000.0;

  final border = '═' * 66;
  stdout.writeln('╔$border╗');
  stdout.writeln('║ ⚡ [hum] Audio Engine Benchmark: ${name.padRight(31)} ║');
  stdout.writeln('╠$border╣');
  stdout.writeln(
    '${'║ Duration:       ${audioDurationSec.toStringAsFixed(1)}s audio ($bars bars @ ${tempo.bpm.round()} BPM)'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ Sample Rate:    $sampleRate Hz | Vector Size: $vectorSize samples'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ Render Time:    ${renderTimeMs.toStringAsFixed(2)} ms ($totalBlocks blocks processed)'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ Throughput:     ${speedFactor.toStringAsFixed(0)}x real-time (${mSamplesPerSec.toStringAsFixed(2)} M samples/sec)'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ Block Latency:  ${usPerBlock.toStringAsFixed(2)} µs / block (budget: ${blockBudgetUs.toStringAsFixed(1)} µs)'.padRight(67)}║',
  );
  stdout.writeln(
    '${'║ DSP Load:       ${dspLoadPct.toStringAsFixed(3)}% of audio callback budget'.padRight(67)}║',
  );
  stdout.writeln('╚$border╝');
}

/// Stateful, block-fed signal analyser capturing per-channel levels, health
/// checks, 4-band spectral energy balance, and per-bar dynamics.
class _AudioAnalyser {
  _AudioAnalyser({
    required this.numChannels,
    required this.sampleRate,
    required this.bars,
    required this.samplesPerBar,
  }) : _peaks = List<double>.filled(numChannels, 0.0),
       _sumSq = List<double>.filled(numChannels, 0.0),
       _sum = List<double>.filled(numChannels, 0.0),
       _clips = List<int>.filled(numChannels, 0),
       _nanOrInf = List<int>.filled(numChannels, 0),
       _finiteCounts = List<int>.filled(numChannels, 0),
       _barPeaks = List<double>.filled(bars, 0.0),
       _barSumSq = List<double>.filled(bars, 0.0),
       _barCounts = List<int>.filled(bars, 0),
       _a100 = math.exp(-2.0 * math.pi * 100.0 / sampleRate),
       _a500 = math.exp(-2.0 * math.pi * 500.0 / sampleRate),
       _a2k = math.exp(-2.0 * math.pi * 2000.0 / sampleRate);

  final int numChannels;
  final int sampleRate;
  final int bars;
  final int samplesPerBar;

  final List<double> _peaks;
  final List<double> _sumSq;
  final List<double> _sum;
  final List<int> _clips;
  final List<int> _nanOrInf;
  final List<int> _finiteCounts;

  final List<double> _barPeaks;
  final List<double> _barSumSq;
  final List<int> _barCounts;

  final double _a100;
  final double _a500;
  final double _a2k;

  double _lp100 = 0.0;
  double _lp500 = 0.0;
  double _lp2k = 0.0;
  double _eSub = 0.0;
  double _eLow = 0.0;
  double _eMid = 0.0;
  double _eHigh = 0.0;

  int _totalFrames = 0;

  int get totalFrames => _totalFrames;

  void feed(List<Float32List> outputs) {
    if (outputs.isEmpty) return;
    final frames = outputs.first.length;
    final chCount = math.min(numChannels, outputs.length);
    final invCh = chCount > 0 ? 1.0 / chCount : 0.0;

    for (int i = 0; i < frames; i++) {
      double mono = 0.0;
      double framePeak = 0.0;
      double frameSqSum = 0.0;
      int finiteInFrame = 0;

      for (int c = 0; c < chCount; c++) {
        final x = outputs[c][i];
        if (!x.isFinite) {
          _nanOrInf[c]++;
          continue;
        }
        final absX = x.abs();
        if (absX > _peaks[c]) _peaks[c] = absX;
        if (absX >= 1.0) _clips[c]++;
        _sumSq[c] += x * x;
        _sum[c] += x;
        _finiteCounts[c]++;

        if (absX > framePeak) framePeak = absX;
        frameSqSum += x * x;
        mono += x;
        finiteInFrame++;
      }

      if (finiteInFrame > 0) {
        mono *= invCh;
        _lp100 = (1.0 - _a100) * mono + _a100 * _lp100;
        _lp500 = (1.0 - _a500) * mono + _a500 * _lp500;
        _lp2k = (1.0 - _a2k) * mono + _a2k * _lp2k;

        final sub = _lp100;
        final low = _lp500 - _lp100;
        final mid = _lp2k - _lp500;
        final high = mono - _lp2k;

        _eSub += sub * sub;
        _eLow += low * low;
        _eMid += mid * mid;
        _eHigh += high * high;
      }

      final barIdx = (_totalFrames ~/ samplesPerBar).clamp(0, bars - 1);
      if (framePeak > _barPeaks[barIdx]) _barPeaks[barIdx] = framePeak;
      _barSumSq[barIdx] += frameSqSum * invCh;
      _barCounts[barIdx]++;

      _totalFrames++;
    }
  }

  Map<String, Object?> toReportMap({
    required String name,
    required Tempo tempo,
    required int vectorSize,
    required int elapsedMs,
    String? outputPath,
  }) {
    final channels = <Map<String, Object?>>[];
    double overallPeak = 0.0;
    double overallSumSq = 0.0;
    int overallFinite = 0;
    int totalClips = 0;
    int totalNanOrInf = 0;

    for (int c = 0; c < numChannels; c++) {
      final count = _finiteCounts[c];
      final peak = _peaks[c];
      final rms = count > 0 ? math.sqrt(_sumSq[c] / count) : 0.0;
      final dc = count > 0 ? _sum[c] / count : 0.0;
      final peakDb = gainToDb(peak);
      final rmsDb = gainToDb(rms);
      final crestDb = peak > 1e-6 && rms > 1e-6 ? peakDb - rmsDb : 0.0;

      if (peak > overallPeak) overallPeak = peak;
      overallSumSq += _sumSq[c];
      overallFinite += count;
      totalClips += _clips[c];
      totalNanOrInf += _nanOrInf[c];

      channels.add({
        'index': c,
        'label': _channelLabel(c, numChannels),
        'peak': _round(peak, 6),
        'peakDb': _round(peakDb, 2),
        'rms': _round(rms, 6),
        'rmsDb': _round(rmsDb, 2),
        'crestDb': _round(crestDb, 2),
        'dcOffset': _round(dc, 6),
        'clips': _clips[c],
        'nanOrInf': _nanOrInf[c],
        'silent': peak <= 1e-6,
      });
    }

    final overallRms =
        overallFinite > 0 ? math.sqrt(overallSumSq / overallFinite) : 0.0;
    final overallPeakDb = gainToDb(overallPeak);
    final overallRmsDb = gainToDb(overallRms);
    final overallCrestDb =
        overallPeak > 1e-6 && overallRms > 1e-6 ? overallPeakDb - overallRmsDb : 0.0;

    final totalBandEnergy = _eSub + _eLow + _eMid + _eHigh;
    final invBand = totalBandEnergy > 1e-12 ? 100.0 / totalBandEnergy : 0.0;

    final timeline = <Map<String, Object?>>[
      for (int b = 0; b < bars; b++)
        () {
          final count = _barCounts[b];
          final rms = count > 0 ? math.sqrt(_barSumSq[b] / count) : 0.0;
          return {
            'bar': b + 1,
            'peakDb': _round(gainToDb(_barPeaks[b]), 2),
            'rmsDb': _round(gainToDb(rms), 2),
          };
        }(),
    ];

    return {
      'name': name,
      'outputPath': ?outputPath,
      'bpm': tempo.bpm,
      'bars': bars,
      'sampleRate': sampleRate,
      'vectorSize': vectorSize,
      'numChannels': numChannels,
      'totalFrames': _totalFrames,
      'durationSec': _round(_totalFrames / sampleRate, 3),
      'renderTimeMs': elapsedMs,
      'overall': {
        'peak': _round(overallPeak, 6),
        'peakDb': _round(overallPeakDb, 2),
        'rms': _round(overallRms, 6),
        'rmsDb': _round(overallRmsDb, 2),
        'crestDb': _round(overallCrestDb, 2),
        'clips': totalClips,
        'nanOrInf': totalNanOrInf,
        'silent': overallPeak <= 1e-6,
      },
      'channels': channels,
      'bandsPct': {
        'sub_lt100Hz': _round(_eSub * invBand, 1),
        'low_100_500Hz': _round(_eLow * invBand, 1),
        'mid_500_2kHz': _round(_eMid * invBand, 1),
        'high_gt2kHz': _round(_eHigh * invBand, 1),
      },
      'barsTimeline': timeline,
    };
  }
}

String _channelLabel(int index, int total) {
  if (total == 1) return 'Mono';
  if (total == 2) return index == 0 ? 'L' : 'R';
  return 'Ch$index';
}

double _round(double value, int decimals) {
  final factor = math.pow(10, decimals);
  return (value * factor).roundToDouble() / factor;
}

void _emitAnalysisReport({
  required _AudioAnalyser analyser,
  required String name,
  required Tempo tempo,
  required int bars,
  required int sampleRate,
  required int vectorSize,
  required int elapsedMs,
  String? outputPath,
  required bool jsonOutput,
}) {
  final report = analyser.toReportMap(
    name: name,
    tempo: tempo,
    vectorSize: vectorSize,
    elapsedMs: elapsedMs,
    outputPath: outputPath,
  );

  if (jsonOutput) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    return;
  }

  final overall = report['overall']! as Map<String, Object?>;
  final channels = report['channels']! as List<Map<String, Object?>>;
  final bands = report['bandsPct']! as Map<String, Object?>;
  final timeline = report['barsTimeline']! as List<Map<String, Object?>>;

  final totalClips = overall['clips']! as int;
  final totalNan = overall['nanOrInf']! as int;
  final isSilent = overall['silent']! as bool;

  final String status;
  if (totalNan > 0) {
    status = '❌ $totalNan NaN/Inf';
  } else if (isSilent) {
    status = '⚠️  SILENT';
  } else if (totalClips > 0) {
    status = '⚠️  CLIPPING ($totalClips)';
  } else {
    status = '✅ Clean (0 clips, 0 NaN/Inf)';
  }

  final durationSec = (report['durationSec']! as double).toStringAsFixed(2);
  final border = '═' * 66;
  String row(String text) => '${'║ $text'.padRight(67)}║';

  stdout.writeln('╔$border╗');
  stdout.writeln(row('📊 [hum] Signal Analysis: $name'));
  stdout.writeln('╠$border╣');
  stdout.writeln(
    row(
      'Duration:   ${durationSec}s ($bars bars @ ${tempo.bpm.round()} BPM, ${analyser.numChannels}ch)',
    ),
  );
  stdout.writeln(
    row(
      'Format:     $sampleRate Hz | VS $vectorSize | Rendered in ${elapsedMs}ms',
    ),
  );
  stdout.writeln(row('Health:     $status'));
  stdout.writeln('╠$border╣');

  for (final ch in channels) {
    final label = (ch['label']! as String).padRight(4);
    final peakDb = (ch['peakDb']! as double).toStringAsFixed(2).padLeft(7);
    final rmsDb = (ch['rmsDb']! as double).toStringAsFixed(2).padLeft(7);
    final crest = (ch['crestDb']! as double).toStringAsFixed(1).padLeft(5);
    final dc = (ch['dcOffset']! as double).toStringAsFixed(4).padLeft(7);
    stdout.writeln(
      row('$label Peak:$peakDb dB | RMS:$rmsDb dB | Crest:$crest | DC:$dc'),
    );
  }

  stdout.writeln('╠$border╣');
  final sub = (bands['sub_lt100Hz']! as double).toStringAsFixed(1);
  final low = (bands['low_100_500Hz']! as double).toStringAsFixed(1);
  final mid = (bands['mid_500_2kHz']! as double).toStringAsFixed(1);
  final high = (bands['high_gt2kHz']! as double).toStringAsFixed(1);
  stdout.writeln(
    row('Spectrum:   <100:$sub% | 100-500:$low% | 500-2k:$mid% | >2k:$high%'),
  );

  stdout.writeln('╠$border╣');
  stdout.writeln(row('Per-Bar RMS / Peak (dBFS):'));
  final buf = StringBuffer();
  for (int i = 0; i < timeline.length; i++) {
    final entry = timeline[i];
    final barNum = (entry['bar']! as int).toString().padLeft(2, '0');
    final rms = (entry['rmsDb']! as double).toStringAsFixed(1).padLeft(5);
    final peak = (entry['peakDb']! as double).toStringAsFixed(1).padLeft(5);
    if (buf.isNotEmpty) buf.write('  ');
    buf.write('B$barNum:$rms/$peak');
    if ((i + 1) % 3 == 0 || i == timeline.length - 1) {
      stdout.writeln(row(buf.toString()));
      buf.clear();
    }
  }
  stdout.writeln('╚$border╝');
}
