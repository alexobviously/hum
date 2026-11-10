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
        vectorSize: 4,
      );

      final left = Float32List.fromList([1.0, 3.0, 5.0, 7.0]);
      final right = Float32List.fromList([2.0, 4.0, 6.0, 8.0]);

      pipedOutput.write([left, right]);
      await pipedOutput.close();

      // 4 samples * 2 channels * 4 bytes = 32 bytes
      expect(accumulatedBytes.length, equals(32));

      final floats = Uint8List.fromList(accumulatedBytes).buffer
          .asFloat32List();
      expect(floats, equals([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]));
    });

    test('Out.stereo routes graph outputs to AudioOutput at engine level', () {
      final memoryOutput = MemoryAudioOutput(numChannels: 2, vectorSize: 4);
      final osc1 = SineOscillator(frequency: .value(440));
      final osc2 = SineOscillator(frequency: .value(880));

      final out = Out.stereo(left: osc1.outlet, right: osc2.outlet);

      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final pipeline = compilePipeline(root: out, context: context).pipeline!;

      // Verify Kahn sort identified Out's 2 inlets as the final graph outputs
      expect(pipeline.outputs.length, equals(2));

      pipeline.process();
      memoryOutput.write(pipeline.outputs);

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

        final channels = [
          Float32List.fromList([1.0, 2.0, 3.0, 4.0]),
          Float32List.fromList([5.0, 6.0, 7.0, 8.0]),
        ];
        combined.write(channels);

        expect(out1.length, equals(32));
        expect(out2.length, equals(32));

        await combined.close();
        expect(out1.isClosed, isTrue);
        expect(out2.isClosed, isTrue);
      },
    );

    test('AudioOutput.none safely drops all blocks', () async {
      final nullOutput = AudioOutput.none(numChannels: 2, vectorSize: 4);
      expect(nullOutput.numChannels, equals(2));
      expect(nullOutput.vectorSize, equals(4));

      nullOutput.write([
        Float32List.fromList([1.0, 2.0, 3.0, 4.0]),
        Float32List.fromList([5.0, 6.0, 7.0, 8.0]),
      ]);

      await nullOutput.close();
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
