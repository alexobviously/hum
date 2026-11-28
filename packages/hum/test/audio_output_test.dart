import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:test/test.dart';

void main() {
  group('AudioOutput & Dac', () {
    test('MemoryAudioOutput accumulates float32 blocks in memory', () async {
      final output = MemoryAudioOutput(numChannels: 2, vectorSize: 4);
      final driver = output.createDriver();

      final left = Float32List.fromList([1.0, 3.0, 5.0, 7.0]);
      final right = Float32List.fromList([2.0, 4.0, 6.0, 8.0]);

      driver.write([left, right]);
      await driver.close();

      // 4 samples * 2 channels * 4 bytes = 32 bytes
      expect(output.length, equals(32));
      expect(output.isClosed, isTrue);

      final floats = output.bytes.buffer.asFloat32List(0, 8);
      expect(floats, equals([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]));
    });

    test('MemoryAudioOutput accumulates pcm16 blocks in memory', () async {
      final output = MemoryAudioOutput(
        numChannels: 1,
        vectorSize: 4,
        format: WavFormat.pcm16,
      );
      final driver = output.createDriver();

      final ch0 = Float32List.fromList([0.0, 1.0, -1.0, 0.5]);
      driver.write([ch0]);
      await driver.close();

      // 4 samples * 1 channel * 2 bytes = 8 bytes
      expect(output.length, equals(8));

      final pcm16 = output.bytes.buffer.asInt16List(0, 4);
      expect(pcm16, equals([0, 32767, -32767, 16384]));
    });

    test('PipedAudioOutput writes interleaved bytes to IOSink', () async {
      final controller = StreamController<List<int>>();
      final accumulatedBytes = <int>[];
      controller.stream.listen(accumulatedBytes.addAll);

      final ioSink = IOSink(controller);
      final pipedOutput = PipedAudioOutput(
        sink: ioSink,
        numChannels: 2,
        vectorSize: 4,
      );
      expect(pipedOutput.isIsolateSendable, isFalse);

      final driver = pipedOutput.createDriver() as PipedAudioOutputDriver;

      final left = Float32List.fromList([1.0, 3.0, 5.0, 7.0]);
      final right = Float32List.fromList([2.0, 4.0, 6.0, 8.0]);

      driver.write([left, right]);
      await driver.close();

      expect(driver.isClosed, isTrue);

      // 4 samples * 2 channels * 4 bytes = 32 bytes
      expect(accumulatedBytes.length, equals(32));

      final floats = Uint8List.fromList(accumulatedBytes).buffer
          .asFloat32List();
      expect(floats, equals([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]));
    });

    test('Out.stereo routes graph outputs to AudioOutput at engine level', () {
      final memoryOutput = MemoryAudioOutput(numChannels: 2, vectorSize: 4);
      final driver = memoryOutput.createDriver();
      final osc1 = SineOscillator(frequency: .value(440));
      final osc2 = SineOscillator(frequency: .value(880));

      final out = Out.stereo(left: osc1.outlet, right: osc2.outlet);

      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final pipeline = compilePipeline(root: out, context: context).pipeline!;

      // Verify Kahn sort identified Out's 2 inlets as the final graph outputs
      expect(pipeline.outputs.length, equals(2));

      pipeline.process();
      driver.write(pipeline.outputs);

      // 4 samples * 2 channels * 4 bytes = 32 bytes
      expect(memoryOutput.length, equals(32));
    });

    test('Out.mono and .out extension act as single-channel DAG terminal', () {
      final osc = SineOscillator(frequency: .value(440));
      final out = Out.mono(osc.outlet);

      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final pipeline = compilePipeline(root: out, context: context).pipeline!;

      expect(pipeline.outputs.length, equals(1));
      expect(out.errors, isEmpty);

      // Test extension syntax
      final outViaExtension = osc.outlet.out;
      expect(outViaExtension.channels.length, equals(1));
      expect(outViaExtension.channels.first, equals(osc.outlet));
    });

    test('Out declares validation errors when channels are empty', () {
      final emptyOut = Out(channels: const []);
      expect(emptyOut.errors, isNotEmpty);
      expect(emptyOut.errors.first.message, contains('[channels]'));
    });

    test(
      'AudioOutput.combine broadcasts blocks to all child outputs',
      () async {
        final out1 = MemoryAudioOutput(numChannels: 2, vectorSize: 4);
        final out2 = MemoryAudioOutput(numChannels: 2, vectorSize: 4);
        final combined = AudioOutput.combine([out1, out2]);

        expect(combined.numChannels, equals(2));
        expect(combined.vectorSize, equals(4));
        expect(combined.isIsolateSendable, isFalse);

        final driver = combined.createDriver();
        final channels = [
          Float32List.fromList([1.0, 2.0, 3.0, 4.0]),
          Float32List.fromList([5.0, 6.0, 7.0, 8.0]),
        ];
        driver.write(channels);

        expect(out1.length, equals(32));
        expect(out2.length, equals(32));

        await driver.close();
        expect(out1.isClosed, isTrue);
        expect(out2.isClosed, isTrue);
      },
    );

    test('AudioOutput.none safely drops all blocks', () async {
      final nullOutput = AudioOutput.none(numChannels: 2, vectorSize: 4);
      expect(nullOutput.numChannels, equals(2));
      expect(nullOutput.vectorSize, equals(4));
      expect(nullOutput.isIsolateSendable, isTrue);

      final driver = nullOutput.createDriver();
      driver.write([
        Float32List.fromList([1.0, 2.0, 3.0, 4.0]),
        Float32List.fromList([5.0, 6.0, 7.0, 8.0]),
      ]);

      await driver.close();
    });

    test(
      'SubprocessSink.ffplay configures low-latency streaming arguments',
      () {
        final osc = SineOscillator(frequency: const .value(440));
        final sink = SubprocessSink.ffplay(
          channels: [osc.outlet],
          sampleRate: 48000,
          format: .pcm16,
        );

        expect(sink.executable, equals('ffplay'));
        expect(sink.format, equals(WavFormat.pcm16));
        expect(sink.arguments, contains('-f'));
        expect(sink.arguments, contains('s16le'));
        expect(sink.arguments, contains('48000'));
        expect(sink.arguments, contains('mono'));
        expect(sink.arguments, contains('-nodisp'));
        expect(sink.arguments, contains('-sync'));
      },
    );

    test('SubprocessSink.sox configures raw play arguments', () {
      final osc1 = SineOscillator(frequency: const .value(440));
      final osc2 = SineOscillator(frequency: const .value(880));
      final sink = SubprocessSink.sox(
        channels: [osc1.outlet, osc2.outlet],
        sampleRate: 44100,
        format: .float32,
      );

      expect(sink.executable, equals('play'));
      expect(sink.format, equals(WavFormat.float32));
      expect(sink.arguments, contains('-t'));
      expect(sink.arguments, contains('raw'));
      expect(sink.arguments, contains('float'));
      expect(sink.arguments, contains('32'));
      expect(sink.arguments, contains('2'));
    });

    test('SubprocessSink supports custom executable override', () {
      final osc = SineOscillator(frequency: const .value(440));
      final sink = SubprocessSink.ffplay(
        channels: [osc.outlet],
        executable: '/opt/homebrew/bin/ffplay',
      );

      expect(sink.executable, equals('/opt/homebrew/bin/ffplay'));
    });

    test('SubprocessSink declares validation errors when invalid', () {
      final emptyChannels = SubprocessSink(
        channels: const [],
        executable: 'ffplay',
      );
      expect(emptyChannels.errors, isNotEmpty);
      expect(emptyChannels.errors.first.message, contains('[channels]'));

      final osc = SineOscillator(frequency: const .value(440));
      final emptyExe = SubprocessSink(
        channels: [osc.outlet],
        executable: '   ',
      );
      expect(emptyExe.errors, isNotEmpty);
      expect(emptyExe.errors.first.message, contains('[executable]'));
    });

    test('SubprocessSink compiles in declarative graph', () {
      final osc = SineOscillator(frequency: const .value(440));
      final sink = SubprocessSink.ffplay(channels: [osc.outlet]);

      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final pipeline = compilePipeline(root: sink, context: context).pipeline!;

      expect(pipeline.outputs.length, equals(1));
      expect(sink.errors, isEmpty);
    });

    test(
      'PipedAudioOutputDriver.close does not hang when called while Process.start is in flight',
      () async {
        final output = PipedAudioOutput(
          executable: 'cat',
          numChannels: 1,
          vectorSize: 4,
        );
        expect(output.isIsolateSendable, isTrue);

        final driver = output.createDriver() as PipedAudioOutputDriver;

        // Trigger lazy Process.start('cat') without awaiting event loop
        driver.write([Float32List(4)]);

        // Immediately close while Process.start is still in flight
        await driver
            .close(waitForExit: false)
            .timeout(
              const Duration(milliseconds: 500),
            );
        expect(driver.isClosed, isTrue);
      },
    );

    test(
      'PipedAudioOutputDriver marks itself closed on Process.start failure to prevent retry storm',
      () async {
        final output = PipedAudioOutput(
          executable: '__nonexistent_hum_executable__',
          numChannels: 1,
          vectorSize: 4,
        );
        final driver = output.createDriver() as PipedAudioOutputDriver;

        driver.write([Float32List(4)]);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(driver.isClosed, isTrue);
      },
    );

    test(
      'SubprocessSinkProcessor.close does not hang when called while Process.start is in flight',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
        final proc = SubprocessSinkProcessor(
          executable: 'cat',
          arguments: const [],
          numChannels: 1,
        );

        // Trigger lazy Process.start('cat') without awaiting event loop
        proc.process(context, [Float32List(4)], const []);

        // Immediately close while Process.start is still in flight
        await proc
            .close(waitForExit: false)
            .timeout(
              const Duration(milliseconds: 500),
            );
        expect(proc.isClosed, isTrue);
      },
    );

    test(
      'SubprocessSinkProcessor marks itself closed on Process.start failure to prevent retry storm',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
        final proc = SubprocessSinkProcessor(
          executable: '__nonexistent_hum_executable__',
          arguments: const [],
          numChannels: 1,
        );

        proc.process(context, [Float32List(4)], const []);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(proc.isClosed, isTrue);
      },
    );

    test(
      'AudioOutput.combine validates matching numChannels and vectorSize',
      () {
        final stereo4 = AudioOutput.none(numChannels: 2, vectorSize: 4);
        final mono4 = AudioOutput.none(numChannels: 1, vectorSize: 4);
        final stereo8 = AudioOutput.none(numChannels: 2, vectorSize: 8);

        expect(
          () => AudioOutput.combine([stereo4, mono4]),
          throwsArgumentError,
        );
        expect(
          () => AudioOutput.combine([stereo4, stereo8]),
          throwsArgumentError,
        );
      },
    );

    test(
      'CombinedAudioOutputDriver.start closes already-started drivers if a later driver throws',
      () async {
        final okDriver = _SpyDriver(numChannels: 2, vectorSize: 4);
        final failingDriver = _SpyDriver(
          numChannels: 2,
          vectorSize: 4,
          failOnStart: true,
        );
        final combined = CombinedAudioOutputDriver(
          drivers: [okDriver, failingDriver],
        );
        final context = ProcessContext(sampleRate: 44100, vectorSize: 4);

        await expectLater(
          () => combined.start(context),
          throwsStateError,
        );
        expect(okDriver.started, isTrue);
        expect(okDriver.closeCalls, equals(1));
        expect(okDriver.lastWaitForExit, isFalse);
      },
    );

    test(
      'PipedAudioOutputDriver drains child stderr so noisy subprocesses do not deadlock',
      () async {
        // Write 256 KB to stderr (exceeds OS pipe buffer) before draining stdin and exiting.
        final output = PipedAudioOutput(
          executable: 'sh',
          arguments: const [
            '-c',
            'dd if=/dev/zero bs=1024 count=256 >&2 2>/dev/null; cat >/dev/null',
          ],
          numChannels: 1,
          vectorSize: 4,
        );
        final AudioOutputDriver driver = output.createDriver();
        final context = ProcessContext(sampleRate: 44100, vectorSize: 4);

        await driver.start(context);
        driver.write([Float32List(4)]);

        await driver
            .close(waitForExit: true)
            .timeout(const Duration(seconds: 2));
        expect((driver as PipedAudioOutputDriver).isClosed, isTrue);
      },
    );

    test(
      'SubprocessSinkProcessor drains child stderr so noisy subprocesses do not deadlock',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
        final proc = SubprocessSinkProcessor(
          executable: 'sh',
          arguments: const [
            '-c',
            'dd if=/dev/zero bs=1024 count=256 >&2 2>/dev/null; cat >/dev/null',
          ],
          numChannels: 1,
        );

        await proc.ensureStarted();
        proc.process(context, [Float32List(4)], const []);

        await proc
            .close(waitForExit: true)
            .timeout(const Duration(seconds: 2));
        expect(proc.isClosed, isTrue);
      },
    );

    test(
      'PipedAudioOutputDriver.start throws ProcessException when executable cannot spawn',
      () async {
        final output = PipedAudioOutput(
          executable: '__nonexistent_hum_executable__',
          numChannels: 1,
          vectorSize: 4,
        );
        final AudioOutputDriver driver = output.createDriver();
        final context = ProcessContext(sampleRate: 44100, vectorSize: 4);

        await expectLater(
          () async => await driver.start(context),
          throwsA(isA<ProcessException>()),
        );
        expect((driver as PipedAudioOutputDriver).isClosed, isTrue);
      },
    );

    test(
      'PipedAudioOutputDriver handles broken pipe cleanly when child exits prematurely',
      () async {
        final unhandledErrors = <Object>[];
        final done = Completer<void>();
        unawaited(
          runZonedGuarded(
            () async {
              final output = PipedAudioOutput(
                executable: 'sh',
                arguments: const ['-c', 'exit 0'],
                numChannels: 1,
                vectorSize: 1024,
              );
              final AudioOutputDriver driver = output.createDriver();
              final context = ProcessContext(
                sampleRate: 44100,
                vectorSize: 1024,
              );

              await driver.start(context);
              await (driver as PipedAudioOutputDriver).process?.exitCode;

              // Write several blocks to the already-closed stdin pipe.
              for (int i = 0; i < 8; i++) {
                driver.write([Float32List(1024)]);
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
              await driver.close(waitForExit: false);
              if (!done.isCompleted) done.complete();
            },
            (error, _) {
              unhandledErrors.add(error);
              if (!done.isCompleted) done.complete();
            },
          ),
        );

        await done.future.timeout(const Duration(seconds: 2));
        expect(unhandledErrors, isEmpty);
      },
    );
  });
}

class _SpyDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
  final bool failOnStart = false,
}) extends AudioOutputDriver {
  bool started = false;
  int closeCalls = 0;
  bool? lastWaitForExit;

  @override
  Future<void> start(ProcessContext context) async {
    if (failOnStart) throw StateError('simulated start failure');
    started = true;
  }

  @override
  void write(List<Float32List> channels) {}

  @override
  Future<void> close({bool waitForExit = true}) async {
    closeCalls++;
    lastWaitForExit = waitForExit;
  }
}
