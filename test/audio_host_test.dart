import 'package:hum/hum.dart';
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
      expect(output.length, greaterThan(0));

      await output.close();
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

    test('startPlayback without AudioOutput runs real-time engine loop', () async {
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
    });

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
  });

  group('AudioHost.spawn (isolate mode)', () {
    test(
      'spawns isolate, applies graph, and renders audio across boundary',
      () async {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final host = await AudioHost.spawn(context: context);

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
        final host = await AudioHost.spawn(context: context);

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
        final host = await AudioHost.spawn(context: context);

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
        expect(output.length, greaterThan(0));

        await output.close();
        await host.dispose();
      },
    );

    test('exportWav bounces audio graph across isolate boundary', () async {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final host = await AudioHost.spawn(context: context);

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
  });
}
