import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:test/test.dart';

void main() {
  group('AudioHost.sync', () {
    test('compiles graph, dispatches diff, and renders audio', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = SyncAudioHost(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final mult = Mult.mono(value: const .value(0.5), input: osc.outlet);

      final diagnostics = host.setGraph(root: mult);
      expect(diagnostics, isEmpty);
      expect(host.currentSnapshot.nodes.length, equals(2));
      expect(host.numChannels, equals(1));

      // Process block
      host.process();
      expect(host.outputs[0].length, equals(64));
      expect(host.outputs[0][1], isNot(equals(0.0)));
    });

    test('returns diagnostics on invalid graph without updating snapshot', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = SyncAudioHost(context: context);

      final invalidSum = Sum(inputs: const []);
      final diagnostics = host.setGraph(root: invalidSum);

      expect(diagnostics.length, equals(1));
      expect(identical(diagnostics.first.node, invalidSum), isTrue);
      expect(host.currentSnapshot.isEmpty, isTrue);
    });

    test('update and updateById update processor in-place', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = SyncAudioHost(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      host.setGraph(root: osc);

      final proc = host.processorOf<SineOscillatorProcessor>(osc)!;
      expect(proc.frequency, equals(440.0));

      // Update via node reference
      host.update(osc, (frequency: 880.0));
      expect(proc.frequency, equals(880.0));

      // Update via ID
      final oscId = host.currentSnapshot.nodeIds[osc]!;
      host.updateById(oscId, (frequency: 220.0));
      expect(proc.frequency, equals(220.0));
    });

    test('renderBlocks renders requested count of blocks', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = AudioHost.sync(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      host.setGraph(root: osc);

      final blocks = await host.renderBlocks(5);
      expect(blocks.length, equals(5));
      for (final block in blocks) {
        expect(block.length, equals(64));
      }
    });

    test('startPlayback and stopPlayback stream blocks with pacing', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = AudioHost.sync(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final dac = Dac.mono(osc.outlet);
      host.setGraph(root: dac);

      final output = MemoryAudioOutput(numChannels: 1, vectorSize: 64);
      expect(host.isPlaying, isFalse);

      await host.startPlayback(output);
      expect(host.isPlaying, isTrue);

      // Play for 40ms to allow blocks to accumulate
      await Future.delayed(const Duration(milliseconds: 40));

      await host.stopPlayback();
      expect(host.isPlaying, isFalse);
      expect(output.isClosed, isTrue);
      expect(output.length, greaterThan(0));

      await host.dispose();
    });

    test('startPlayback validates channel count and vector size', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = AudioHost.sync(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final dac = Dac.mono(osc.outlet);

      // Calling startPlayback before setGraph throws StateError
      final output1 = MemoryAudioOutput(numChannels: 1, vectorSize: 64);
      expect(() => host.startPlayback(output1), throwsStateError);

      host.setGraph(root: dac);

      // Channel mismatch throws ArgumentError
      final mismatchChannels = MemoryAudioOutput(
        numChannels: 2,
        vectorSize: 64,
      );
      expect(() => host.startPlayback(mismatchChannels), throwsArgumentError);

      // Vector size mismatch throws ArgumentError
      final mismatchVector = MemoryAudioOutput(numChannels: 1, vectorSize: 128);
      expect(() => host.startPlayback(mismatchVector), throwsArgumentError);
    });

    test('dispose automatically closes all sink nodes in graph', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = SyncAudioHost(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final wavSink = WavSink.memory(channels: [osc.outlet]);
      host.setGraph(root: wavSink);

      final proc = host.processorOf<WavSinkProcessor>(wavSink)!;
      expect(proc.isClosed, isFalse);

      await host.renderBlocks(2);
      expect(proc.isClosed, isFalse);

      await host.dispose();
      expect(proc.isClosed, isTrue);
    });

    test('replacing graph disposes removed sink processors', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = SyncAudioHost(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final wavSink = WavSink.memory(channels: [osc.outlet]);
      host.setGraph(root: wavSink);

      final proc = host.processorOf<WavSinkProcessor>(wavSink)!;
      expect(proc.isClosed, isFalse);

      // Replace graph without wavSink
      host.setGraph(root: osc);
      expect(proc.isClosed, isTrue);

      await host.dispose();
    });

    test(
      'startPlayback without AudioOutput runs real-time engine loop',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = AudioHost.sync(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        host.setGraph(root: osc.out);

        expect(host.isPlaying, isFalse);
        await host.startPlayback();
        expect(host.isPlaying, isTrue);

        await Future.delayed(const Duration(milliseconds: 30));
        await host.stopPlayback();
        expect(host.isPlaying, isFalse);
        await host.dispose();
      },
    );

    test('exportWav bounces audio graph offline at max CPU speed', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = AudioHost.sync(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final out = Out.stereo(left: osc.outlet, right: osc.outlet);
      host.setGraph(root: out);

      // Bounce 100ms of stereo float32 audio
      final wavBytes = await host.exportWav(
        duration: const Duration(milliseconds: 100),
        format: .float32,
      );

      // 44-byte header + data
      expect(wavBytes.length, greaterThan(44));
      // First 4 bytes are 'RIFF'
      expect(String.fromCharCodes(wavBytes.sublist(0, 4)), equals('RIFF'));
      // Bytes 8-12 are 'WAVE'
      expect(String.fromCharCodes(wavBytes.sublist(8, 12)), equals('WAVE'));

      await host.dispose();
    });

    test(
      'stopPlayback does not hang when driver.close throws an exception',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = AudioHost.sync(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        host.setGraph(root: osc.out);

        final failingOutput = _ThrowingCloseOutput(
          numChannels: 1,
          vectorSize: 64,
        );
        await host.startPlayback(failingOutput);
        await Future.delayed(const Duration(milliseconds: 20));

        await host.stopPlayback().timeout(const Duration(milliseconds: 500));
        expect(host.isPlaying, isFalse);

        await host.dispose();
      },
    );
  });

  group('AudioHost.spawn (isolate mode)', () {
    test(
      'spawns isolate, applies graph, and renders audio across boundary',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        final mult = Mult.mono(value: const .value(0.5), input: osc.outlet);

        final diagnostics = host.setGraph(root: mult);
        expect(diagnostics, isEmpty);
        expect(host.currentSnapshot.nodes.length, equals(2));

        // Render blocks across isolate boundary
        final blocks440 = await host.renderBlocks(2);
        expect(blocks440.length, equals(2));
        expect(blocks440[0].length, equals(64));
        expect(blocks440[0][1], isNot(equals(0.0)));

        // Fast-path parameter update across isolate boundary
        host.update(osc, (frequency: 880.0));

        final blocks880 = await host.renderBlocks(2);
        expect(blocks880.length, equals(2));
        expect(blocks880[0].length, equals(64));

        // Clean disposal
        await host.dispose();

        // Subsequent operations throw StateError
        expect(
          () => host.setGraph(root: osc),
          throwsStateError,
        );
      },
    );

    test(
      'returns diagnostics on invalid graph without sending to worker',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);

        final invalidSum = Sum(inputs: const []);
        final diagnostics = host.setGraph(root: invalidSum);

        expect(diagnostics.length, equals(1));
        expect(identical(diagnostics.first.node, invalidSum), isTrue);
        expect(host.currentSnapshot.isEmpty, isTrue);

        await host.dispose();
      },
    );

    test(
      'startPlayback and stopPlayback stream blocks across isolate boundary',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        final dac = Dac.mono(osc.outlet);
        host.setGraph(root: dac);

        final output = MemoryAudioOutput(numChannels: 1, vectorSize: 64);
        expect(host.isPlaying, isFalse);

        await host.startPlayback(output);
        expect(host.isPlaying, isTrue);

        // Play for 50ms to allow blocks to stream across isolate
        await Future.delayed(const Duration(milliseconds: 50));

        await host.stopPlayback();
        expect(host.isPlaying, isFalse);
        expect(output.isClosed, isTrue);
        expect(output.length, greaterThan(0));

        await host.dispose();
      },
    );

    test('exportWav bounces audio graph across isolate boundary', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = await IsolateAudioHost.spawn(context: context);

      final osc = SineOscillator(frequency: const .value(440));
      final out = Out.stereo(left: osc.outlet, right: osc.outlet);
      host.setGraph(root: out);

      final wavBytes = await host.exportWav(
        duration: const Duration(milliseconds: 100),
        format: .pcm16,
      );

      expect(wavBytes.length, greaterThan(44));
      expect(String.fromCharCodes(wavBytes.sublist(0, 4)), equals('RIFF'));
      expect(String.fromCharCodes(wavBytes.sublist(8, 12)), equals('WAVE'));

      await host.dispose();
    });

    test(
      'startPlayback runs sendable AudioOutput directly on worker isolate',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        host.setGraph(root: osc.out);

        final nullOutput = AudioOutput.none(numChannels: 1, vectorSize: 64);
        await host.startPlayback(nullOutput);
        expect(host.isPlaying, isTrue);

        await Future.delayed(const Duration(milliseconds: 30));
        await host.stopPlayback();
        expect(host.isPlaying, isFalse);

        // Verify PipedAudioOutput.ffplay / .sox are isolate-sendable prior to spawning
        final ffplayOut = PipedAudioOutput.ffplay(
          numChannels: 1,
          vectorSize: 64,
          sampleRate: 44100,
        );
        expect(ffplayOut.isIsolateSendable, isTrue);

        await host.dispose();
      },
    );

    test(
      'custom AudioOutput and PlaybackPacer run directly on worker isolate',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        host.setGraph(root: osc.out);

        final events = <String>[];
        final eventPort = ReceivePort();
        final sub = eventPort.listen((msg) => events.add(msg as String));

        final customOutput = _WorkerProbeAudioOutput(
          numChannels: 1,
          vectorSize: 64,
          replyPort: eventPort.sendPort,
        );

        await host.startPlayback(customOutput);
        await Future.delayed(const Duration(milliseconds: 25));
        await host.stopPlayback();

        expect(events, contains('driver.start:hum_engine'));
        expect(events, contains('pacer.start:hum_engine'));
        expect(events, contains('pacer.wait:hum_engine'));
        expect(events, contains('driver.write:hum_engine'));
        expect(events, contains('pacer.processed:hum_engine'));
        expect(events, contains('pacer.stop:hum_engine'));
        expect(events, contains('driver.close:hum_engine'));

        await sub.cancel();
        eventPort.close();
        await host.dispose();
      },
    );

    test(
      'stopPlayback does not hang when worker driver.close throws an exception',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        host.setGraph(root: osc.out);

        final failingOutput = _ThrowingCloseOutput(
          numChannels: 1,
          vectorSize: 64,
        );
        await host.startPlayback(failingOutput);
        await Future.delayed(const Duration(milliseconds: 20));

        await host.stopPlayback().timeout(const Duration(milliseconds: 500));
        expect(host.isPlaying, isFalse);

        await host.dispose();
      },
    );

    test(
      'dispose does not double-close active worker driver after unawaited stopPlayback',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        host.setGraph(root: osc.out);

        final events = <String>[];
        final eventPort = ReceivePort();
        final sub = eventPort.listen((msg) => events.add(msg as String));

        final output = _LifecycleCountingOutput(
          id: 'single_close',
          numChannels: 1,
          vectorSize: 64,
          replyPort: eventPort.sendPort,
          startDelay: Duration.zero,
          closeDelay: const Duration(milliseconds: 15),
        );

        await host.startPlayback(output);
        await Future.delayed(const Duration(milliseconds: 15));

        unawaited(host.stopPlayback());
        await host.dispose();
        await Future.delayed(const Duration(milliseconds: 30));

        final closes = events.where((e) => e == 'single_close:close').length;
        expect(closes, equals(1));

        await sub.cancel();
        eventPort.close();
      },
    );

    test(
      'start -> stop -> start race during slow driver.start ignores stale session',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);

        final osc = SineOscillator(frequency: const .value(440));
        host.setGraph(root: osc.out);

        final events = <String>[];
        final eventPort = ReceivePort();
        final sub = eventPort.listen((msg) => events.add(msg as String));

        final slowOutput = _LifecycleCountingOutput(
          id: 'slow',
          numChannels: 1,
          vectorSize: 64,
          replyPort: eventPort.sendPort,
          startDelay: const Duration(milliseconds: 40),
        );
        final fastOutput = _LifecycleCountingOutput(
          id: 'fast',
          numChannels: 1,
          vectorSize: 64,
          replyPort: eventPort.sendPort,
          startDelay: Duration.zero,
        );

        unawaited(host.startPlayback(slowOutput));
        unawaited(host.stopPlayback());
        unawaited(host.startPlayback(fastOutput));

        await Future.delayed(const Duration(milliseconds: 80));
        await host.stopPlayback();

        expect(events, contains('fast:write'));
        expect(events, isNot(contains('slow:write')));
        expect(events.where((e) => e == 'slow:close').length, equals(1));
        expect(events.where((e) => e == 'fast:close').length, equals(1));

        await sub.cancel();
        eventPort.close();
        await host.dispose();
      },
    );
  });
}

class const _WorkerProbeAudioOutput({
  @override required final int numChannels,
  @override required final int vectorSize,
  required final SendPort replyPort,
}) extends AudioOutput {
  @override
  bool get isIsolateSendable => true;

  @override
  AudioOutputDriver createDriver() => _WorkerProbeDriver(
    numChannels: numChannels,
    vectorSize: vectorSize,
    replyPort: replyPort,
  );
}

class _WorkerProbeDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
  required final SendPort replyPort,
}) extends AudioOutputDriver {
  final Set<String> _seen = {};

  void _emitOnce(String name) {
    if (_seen.add(name)) {
      replyPort.send('$name:${Isolate.current.debugName}');
    }
  }

  @override
  Future<void> start(ProcessContext context) async {
    _emitOnce('driver.start');
  }

  @override
  PlaybackPacer createPacer(ProcessContext context) =>
      _WorkerProbePacer(_emitOnce);

  @override
  void write(List<Float32List> channels) {
    _emitOnce('driver.write');
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    _emitOnce('driver.close');
  }
}

class _WorkerProbePacer(final void Function(String) emitOnce)
    extends PlaybackPacer {
  Timer? _timer;
  Completer<void>? _completer;

  @override
  void start() => emitOnce('pacer.start');

  @override
  FutureOr<void> waitForNextBlock() {
    emitOnce('pacer.wait');
    final completer = _completer = Completer<void>();
    _timer = Timer(const Duration(milliseconds: 5), () {
      _timer = null;
      _completer = null;
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  @override
  void onBlockProcessed() => emitOnce('pacer.processed');

  @override
  void stop() {
    emitOnce('pacer.stop');
    _timer?.cancel();
    _timer = null;
    final completer = _completer;
    _completer = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}

class const _ThrowingCloseOutput({
  @override required final int numChannels,
  @override required final int vectorSize,
}) extends AudioOutput {
  @override
  bool get isIsolateSendable => true;

  @override
  AudioOutputDriver createDriver() => _ThrowingCloseDriver(
    numChannels: numChannels,
    vectorSize: vectorSize,
  );
}

class _ThrowingCloseDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
}) extends AudioOutputDriver {
  @override
  void write(List<Float32List> channels) {}

  @override
  Future<void> close({bool waitForExit = true}) async {
    throw StateError('simulated close failure');
  }
}

class const _LifecycleCountingOutput({
  required final String id,
  @override required final int numChannels,
  @override required final int vectorSize,
  required final SendPort replyPort,
  final Duration startDelay = Duration.zero,
  final Duration closeDelay = Duration.zero,
}) extends AudioOutput {
  @override
  bool get isIsolateSendable => true;

  @override
  AudioOutputDriver createDriver() => _LifecycleCountingDriver(
    id: id,
    numChannels: numChannels,
    vectorSize: vectorSize,
    replyPort: replyPort,
    startDelay: startDelay,
    closeDelay: closeDelay,
  );
}

class _LifecycleCountingDriver({
  required final String id,
  @override required final int numChannels,
  @override required final int vectorSize,
  required final SendPort replyPort,
  required final Duration startDelay,
  required final Duration closeDelay,
}) extends AudioOutputDriver {
  @override
  Future<void> start(ProcessContext context) async {
    if (startDelay > Duration.zero) {
      await Future.delayed(startDelay);
    }
    replyPort.send('$id:start');
  }

  @override
  void write(List<Float32List> channels) {
    replyPort.send('$id:write');
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    if (closeDelay > Duration.zero) {
      await Future.delayed(closeDelay);
    }
    replyPort.send('$id:close');
  }
}
