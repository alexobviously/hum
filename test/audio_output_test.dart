import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('AudioOutput & Dac', () {
    test('MemoryAudioOutput accumulates float32 blocks in memory', () {
      final output = MemoryAudioOutput(numChannels: 2, vectorSize: 4);

      final left = Float32List.fromList([1.0, 3.0, 5.0, 7.0]);
      final right = Float32List.fromList([2.0, 4.0, 6.0, 8.0]);

      output.write([left, right]);

      // 4 samples * 2 channels * 4 bytes = 32 bytes
      expect(output.length, equals(32));

      final floats = output.bytes.buffer.asFloat32List(0, 8);
      expect(floats, equals([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]));
    });

    test('MemoryAudioOutput accumulates pcm16 blocks in memory', () {
      final output = MemoryAudioOutput(
        numChannels: 1,
        vectorSize: 4,
        format: WavFormat.pcm16,
      );

      final ch0 = Float32List.fromList([0.0, 1.0, -1.0, 0.5]);
      output.write([ch0]);

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
        vectorSize: 2,
      );

      final left = Float32List.fromList([1.0, 3.0]);
      final right = Float32List.fromList([2.0, 4.0]);

      pipedOutput.write([left, right]);
      await pipedOutput.close();

      // 2 samples * 2 channels * 4 bytes = 16 bytes
      expect(accumulatedBytes.length, equals(16));

      final floats = Uint8List.fromList(accumulatedBytes).buffer
          .asFloat32List();
      expect(floats, equals([1.0, 2.0, 3.0, 4.0]));
    });

    test('Dac.stereo routes graph outputs to AudioOutput at engine level', () {
      final memoryOutput = MemoryAudioOutput(numChannels: 2, vectorSize: 4);
      final osc1 = SineOscillator(frequency: .value(440));
      final osc2 = SineOscillator(frequency: .value(880));

      final dac = Dac.stereo(left: osc1.outlet, right: osc2.outlet);

      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final pipeline = compilePipeline(root: dac, context: context).pipeline!;

      // Verify Kahn sort identified Dac's 2 inlets as the final graph outputs
      expect(pipeline.outputs.length, equals(2));

      pipeline.process();
      memoryOutput.write(pipeline.outputs);

      // 4 samples * 2 channels * 4 bytes = 32 bytes
      expect(memoryOutput.length, equals(32));
    });

    test('Dac.mono acts as single-channel DAG terminal', () {
      final osc = SineOscillator(frequency: .value(440));
      final dac = Dac.mono(osc.outlet);

      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final pipeline = compilePipeline(root: dac, context: context).pipeline!;

      expect(pipeline.outputs.length, equals(1));
      expect(dac.errors, isEmpty);
    });

    test('Dac declares validation errors when channels are empty', () {
      final emptyDac = Dac(channels: const []);
      expect(emptyDac.errors, isNotEmpty);
      expect(emptyDac.errors.first.message, contains('[channels]'));
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
  });
}
