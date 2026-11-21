import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hum/hum.dart';
import 'package:hum_flutter/hum_flutter.dart';

class _TestMemoryOutput extends AudioOutput {
  const _TestMemoryOutput({
    required this.numChannels,
    required this.vectorSize,
  });

  @override
  final int numChannels;

  @override
  final int vectorSize;

  @override
  bool get isIsolateSendable => false;

  @override
  AudioOutputDriver createDriver() =>
      _TestMemoryOutputDriver(numChannels: numChannels, vectorSize: vectorSize);
}

class _TestMemoryOutputDriver extends AudioOutputDriver {
  _TestMemoryOutputDriver({
    required this.numChannels,
    required this.vectorSize,
  });

  @override
  final int numChannels;

  @override
  final int vectorSize;

  int blocksWritten = 0;

  @override
  void start(ProcessContext context) {}

  @override
  void write(List<Float32List> channels) {
    blocksWritten++;
  }

  @override
  Future<void> close({bool waitForExit = true}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HumAudioSession', () {
    test('starts, updates, stops, and disposes idempotently', () async {
      bool onDisposeCalled = false;
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = AudioHost.sync(context: context);
      const output = _TestMemoryOutput(numChannels: 2, vectorSize: 64);

      final session = HumAudioSession(
        host: host,
        output: output,
        outputChannels: 2,
        onDispose: () async => onDisposeCalled = true,
      );

      final osc = SineOscillator(frequency: const .value(440));
      final out = Out.stereo(left: osc.outlet, right: osc.outlet);
      expect(session.setGraph(root: out), isEmpty);

      await session.start();
      expect(session.isPlaying, isTrue);

      session.update(osc, (frequency: 880.0, interpTime: 0.01));
      await session.stop();
      expect(session.isPlaying, isFalse);

      await session.dispose();
      await session.dispose();
      expect(session.isDisposed, isTrue);
      expect(onDisposeCalled, isTrue);
      expect(session.start, throwsStateError);
    });
  });

  group('HumAudioController', () {
    test('manages lifecycle, graph setup, updates, and teardown', () async {
      int disposeCount = 0;
      final controller = HumAudioController(
        pauseOnBackground: false,
        sessionOpener:
            ({
              bool enableOutput = true,
              bool enableInput = false,
              int? sampleRate,
              int? vectorSize,
              int? outputChannels,
              int? inputChannels,
              int bufferFrames = 2048,
              String? outputDeviceId,
              String? inputDeviceId,
            }) async {
              final sr = sampleRate ?? 48000;
              final vs = vectorSize ?? 64;
              final ch = outputChannels ?? 2;
              return HumAudioSession(
                host: AudioHost.sync(
                  context: ProcessContext(sampleRate: sr, vectorSize: vs),
                ),
                output: _TestMemoryOutput(numChannels: ch, vectorSize: vs),
                outputChannels: ch,
                onDispose: () async => disposeCount++,
              );
            },
      );

      late SineOscillator osc;
      await controller.start(
        buildGraph: (session) {
          osc = SineOscillator(frequency: const .value(220));
          return Out.stereo(left: osc.outlet, right: osc.outlet);
        },
      );

      expect(controller.isPlaying, isTrue);
      expect(controller.isStarting, isFalse);
      expect(controller.lastError, isNull);
      expect(controller.session, isNotNull);

      controller.update(osc, (frequency: 440.0, interpTime: 0.01));

      await controller.stop();
      expect(controller.isPlaying, isFalse);
      expect(controller.session, isNull);
      expect(disposeCount, 1);

      controller.dispose();
    });

    test('stops playback automatically on AppLifecycleState.paused', () async {
      final controller = HumAudioController(
        pauseOnBackground: true,
        sessionOpener:
            ({
              bool enableOutput = true,
              bool enableInput = false,
              int? sampleRate,
              int? vectorSize,
              int? outputChannels,
              int? inputChannels,
              int bufferFrames = 2048,
              String? outputDeviceId,
              String? inputDeviceId,
            }) async {
              return HumAudioSession(
                host: AudioHost.sync(
                  context: const ProcessContext(
                    sampleRate: 48000,
                    vectorSize: 64,
                  ),
                ),
                output: const _TestMemoryOutput(numChannels: 2, vectorSize: 64),
                outputChannels: 2,
              );
            },
      );

      await controller.start(
        buildGraph: (_) {
          final osc = SineOscillator(frequency: const .value(440));
          return Out.stereo(left: osc.outlet, right: osc.outlet);
        },
      );
      expect(controller.isPlaying, isTrue);

      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.isPlaying, isFalse);
      expect(controller.session, isNull);

      controller.dispose();
    });
  });
}
