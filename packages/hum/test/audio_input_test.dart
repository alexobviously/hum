import 'dart:async';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:test/test.dart';

void main() {
  group('In node & AudioInput', () {
    test('In declares expected outlets and validates channel indices', () {
      final mono = In.mono();
      expect(mono.inlets, isEmpty);
      expect(mono.outlets.length, equals(1));
      expect(mono.outlet, equals(mono.outlets.first));
      expect(mono.channels, equals([0]));
      expect(mono.errors, isEmpty);

      final stereo = In.stereo();
      expect(stereo.outlets.length, equals(2));
      expect(stereo.left, equals(stereo.outlets[0]));
      expect(stereo.right, equals(stereo.outlets[1]));
      expect(stereo.channels, equals([0, 1]));
      expect(stereo.errors, isEmpty);

      final custom = In(channels: [2, 3]);
      expect(custom.outlets.length, equals(2));
      expect(custom.channels, equals([2, 3]));
      expect(custom.errors, isEmpty);

      final empty = In(channels: const []);
      expect(empty.errors, isNotEmpty);

      final negative = In(channels: [-1]);
      expect(negative.errors, isNotEmpty);
    });

    test('InProcessor outputs silence when unbound or out of range', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final proc = In(channels: [0, 5]).createProcessor();
      final out0 = Float32List.fromList([1.0, 1.0, 1.0, 1.0]);
      final out1 = Float32List.fromList([1.0, 1.0, 1.0, 1.0]);

      // Unbound -> silence
      proc.process(context, const [], [out0, out1]);
      expect(out0, everyElement(0.0));
      expect(out1, everyElement(0.0));

      // Bound to 1-channel input -> channel 0 reads data, channel 5 is silent
      proc.bindInputs([
        Float32List.fromList([0.25, 0.5, 0.75, 1.0]),
      ]);
      out1.fillRange(0, 4, 1.0);
      proc.process(context, const [], [out0, out1]);
      expect(out0, equals([0.25, 0.5, 0.75, 1.0]));
      expect(out1, everyElement(0.0));
    });

    test('MemoryAudioInput reads samples, zero-fills after EOF, and loops', () {
      final src = Float32List.fromList([1.0, 2.0, 3.0, 4.0, 5.0, 6.0]);
      final target = [Float32List(4)];

      final oneShot =
          MemoryAudioInput(channels: [src], vectorSize: 4).createDriver()
              as MemoryAudioInputDriver;
      oneShot.read(target);
      expect(target[0], equals([1.0, 2.0, 3.0, 4.0]));
      oneShot.read(target);
      expect(target[0], equals([5.0, 6.0, 0.0, 0.0]));
      oneShot.read(target);
      expect(target[0], equals([0.0, 0.0, 0.0, 0.0]));

      final looping =
          MemoryAudioInput(
                channels: [src],
                vectorSize: 4,
                loop: true,
              ).createDriver()
              as MemoryAudioInputDriver;
      looping.read(target);
      expect(target[0], equals([1.0, 2.0, 3.0, 4.0]));
      looping.read(target);
      expect(target[0], equals([5.0, 6.0, 1.0, 2.0]));
    });

    test('SyncAudioHost duplex streams MemoryAudioInput through DSP to output', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = AudioHost.sync(context: context);

      // Select channel 1 (right) from a 2-channel input and double it
      final ch0 = Float32List(64)..fillRange(0, 64, 0.1);
      final ch1 = Float32List(64)..fillRange(0, 64, 0.25);
      final input = MemoryAudioInput(
        channels: [ch0, ch1],
        vectorSize: 64,
        loop: true,
      );
      final output = MemoryAudioOutput(numChannels: 1, vectorSize: 64);

      final mic = In.mono(1);
      final boosted = Mult.mono(
        input: mic.outlet,
        value: const .value(2.0),
        interpTime: 0.0,
      );
      expect(host.setGraph(root: boosted.out), isEmpty);

      await host.startPlayback(output: output, input: input);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await host.stopPlayback();

      expect(output.length, greaterThan(0));
      final samples = output.bytes.buffer.asFloat32List();
      expect(samples.first, closeTo(0.5, 1e-6));

      await host.dispose();
    });

    test('SyncAudioHost validates input vectorSize', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = AudioHost.sync(context: context);
      host.setGraph(root: In.mono().out);

      final badInput = AudioInput.none(numChannels: 1, vectorSize: 32);
      expect(
        () => host.startPlayback(input: badInput),
        throwsArgumentError,
      );

      await host.dispose();
    });

    test('SyncAudioHost supports input-only playback with WavSink and no Out', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = AudioHost.sync(context: context) as SyncAudioHost;

      final src = Float32List(64)..fillRange(0, 64, 0.4);
      final input = MemoryAudioInput(
        channels: [src],
        vectorSize: 64,
        loop: true,
      );
      final mic = In.mono();
      final sink = WavSink.memory(channels: [mic.outlet]);
      expect(host.setGraph(root: sink), isEmpty);

      await host.startPlayback(input: input);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await host.stopPlayback();

      final proc = host.processorOf<WavSinkProcessor>(sink)!;
      final wavBytes = proc.close()!;
      expect(wavBytes.length, greaterThan(44));
      await host.dispose();
    });

    test(
      'IsolateAudioHost streams MemoryAudioInput through worker isolate to output',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);

        final src = Float32List(64)..fillRange(0, 64, 0.3);
        final input = MemoryAudioInput(
          channels: [src],
          vectorSize: 64,
          loop: true,
        );
        final output = MemoryAudioOutput(numChannels: 1, vectorSize: 64);

        final mic = In.mono();
        final scaled = Mult.mono(
          input: mic.outlet,
          value: const .value(2.0),
          interpTime: 0.0,
        );
        expect(host.setGraph(root: scaled.out), isEmpty);

        await host.startPlayback(output: output, input: input);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await host.stopPlayback();

        expect(output.length, greaterThan(0));
        final samples = output.bytes.buffer.asFloat32List();
        expect(samples.first, closeTo(0.6, 1e-6));

        await host.dispose();
      },
    );

    test(
      'IsolateAudioHost rejects non-sendable AudioInput with ArgumentError',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await IsolateAudioHost.spawn(context: context);
        host.setGraph(root: In.mono().out);

        final nonSendable = _NonSendableInput(numChannels: 1, vectorSize: 64);
        expect(
          () => host.startPlayback(input: nonSendable),
          throwsArgumentError,
        );

        await host.dispose();
      },
    );

    test('SyncAudioHost uses input pacer when no output is provided', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = AudioHost.sync(context: context);
      host.setGraph(root: In.mono().out);

      int pacerWaits = 0;
      final input = _CustomPacerInput(
        numChannels: 1,
        vectorSize: 64,
        onWait: () => pacerWaits++,
      );

      await host.startPlayback(input: input);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await host.stopPlayback();

      expect(pacerWaits, greaterThan(0));
      await host.dispose();
    });
  });
}

class _NonSendableInput({
  @override required final int numChannels,
  @override required final int vectorSize,
}) extends AudioInput {
  @override
  bool get isIsolateSendable => false;

  @override
  AudioInputDriver createDriver() =>
      NullAudioInputDriver(numChannels: numChannels, vectorSize: vectorSize);
}

class _CustomPacerInput({
  @override required final int numChannels,
  @override required final int vectorSize,
  required final void Function() onWait,
}) extends AudioInput {
  @override
  AudioInputDriver createDriver() => _CustomPacerInputDriver(
    numChannels: numChannels,
    vectorSize: vectorSize,
    onWait: onWait,
  );
}

class _CustomPacerInputDriver({
  @override required final int numChannels,
  @override required final int vectorSize,
  required final void Function() onWait,
}) extends AudioInputDriver {
  @override
  PlaybackPacer createPacer(ProcessContext context) =>
      _CountingPacer(onWait: onWait);

  @override
  void read(List<Float32List> channels) {
    for (final ch in channels) {
      ch.fillRange(0, vectorSize, 0.0);
    }
  }

  @override
  Future<void> close({bool waitForExit = true}) async {}
}

class _CountingPacer({required final void Function() onWait})
    extends PlaybackPacer {
  bool _stopped = false;

  @override
  void start() {
    _stopped = false;
  }

  @override
  FutureOr<void> waitForNextBlock() {
    if (_stopped) return null;
    onWait();
    return Future<void>.delayed(const Duration(milliseconds: 5));
  }

  @override
  void stop() {
    _stopped = true;
  }
}
