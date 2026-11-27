import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:test/test.dart';

Uint8List _buildCustomWav({
  required int formatTag,
  required int numChannels,
  required int sampleRate,
  required int bitsPerSample,
  required Uint8List pcmBytes,
  bool includeJunkChunk = false,
  bool extensible = false,
}) {
  final builder = BytesBuilder();

  final fmtSize = extensible ? 40 : 16;
  final fmt = ByteData(8 + fmtSize);
  fmt.setUint8(0, 'f'.codeUnitAt(0));
  fmt.setUint8(1, 'm'.codeUnitAt(0));
  fmt.setUint8(2, 't'.codeUnitAt(0));
  fmt.setUint8(3, ' '.codeUnitAt(0));
  fmt.setUint32(4, fmtSize, Endian.little);
  fmt.setUint16(8, extensible ? 0xFFFE : formatTag, Endian.little);
  fmt.setUint16(10, numChannels, Endian.little);
  fmt.setUint32(12, sampleRate, Endian.little);
  final blockAlign = numChannels * (bitsPerSample ~/ 8);
  fmt.setUint32(16, sampleRate * blockAlign, Endian.little);
  fmt.setUint16(20, blockAlign, Endian.little);
  fmt.setUint16(22, bitsPerSample, Endian.little);
  if (extensible) {
    fmt.setUint16(24, 22, Endian.little); // cbSize
    fmt.setUint16(26, bitsPerSample, Endian.little); // wValidBitsPerSample
    fmt.setUint32(28, 0, Endian.little); // dwChannelMask
    fmt.setUint16(32, formatTag, Endian.little); // SubFormat GUID tag
  }

  final body = BytesBuilder();
  if (includeJunkChunk) {
    // Odd-length JUNK chunk (5 bytes + 1 pad byte) to test RIFF alignment.
    body.add('JUNK'.codeUnits);
    final sz = ByteData(4)..setUint32(0, 5, Endian.little);
    body.add(sz.buffer.asUint8List());
    body.add([1, 2, 3, 4, 5, 0]);
  }
  body.add(fmt.buffer.asUint8List());
  body.add('data'.codeUnits);
  final dataSz = ByteData(4)..setUint32(0, pcmBytes.length, Endian.little);
  body.add(dataSz.buffer.asUint8List());
  body.add(pcmBytes);

  final bodyBytes = body.takeBytes();
  builder.add('RIFF'.codeUnits);
  final riffSz = ByteData(4)..setUint32(0, 4 + bodyBytes.length, Endian.little);
  builder.add(riffSz.buffer.asUint8List());
  builder.add('WAVE'.codeUnits);
  builder.add(bodyBytes);
  return builder.takeBytes();
}

void main() {
  group('AudioBuffer & BufferHandle', () {
    test('constructs mono, stereo, silence, and de-interleaved buffers', () {
      final mono = AudioBuffer.mono(
        Float32List.fromList([0.25, -0.5, 0.75]),
        sampleRate: 48000,
      );
      expect(mono.numChannels, equals(1));
      expect(mono.length, equals(3));
      expect(mono[0][1], closeTo(-0.5, 1e-6));

      final stereo = AudioBuffer.fromInterleaved(
        Float32List.fromList([0.1, 0.2, 0.3, 0.4, 0.5, 0.6]),
        numChannels: 2,
        sampleRate: 44100,
      );
      expect(stereo.numChannels, equals(2));
      expect(stereo.length, equals(3));
      expect(stereo[0][0], closeTo(0.1, 1e-6));
      expect(stereo[1][0], closeTo(0.2, 1e-6));
      expect(stereo[0][2], closeTo(0.5, 1e-6));
      expect(stereo[1][2], closeTo(0.6, 1e-6));

      final silent = AudioBuffer.silence(
        length: 128,
        sampleRate: 48000,
        numChannels: 2,
      );
      expect(silent.numChannels, equals(2));
      expect(silent.length, equals(128));
      expect(silent[0][0], equals(0.0));
    });

    test('BufferHandle has value equality and durationSeconds', () {
      const a = BufferHandle(
        id: BufferId(1),
        sampleRate: 48000,
        numChannels: 2,
        length: 24000,
      );
      const b = BufferHandle(
        id: BufferId(1),
        sampleRate: 48000,
        numChannels: 2,
        length: 24000,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.durationSeconds, closeTo(0.5, 1e-9));
    });
  });

  group('readWav / loadWav', () {
    test('round-trips float32 and pcm16 WAV via exportWav and loadWav', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(context: context);
      final oscL = SineOscillator(frequency: const .value(440.0));
      final oscR = SineOscillator(frequency: const .value(880.0));
      host.setGraph(root: Out.stereo(left: oscL.outlet, right: oscR.outlet));

      final floatBytes = await host.exportWav(
        duration: const Duration(milliseconds: 10),
        format: .float32,
      );
      final floatBuf = readWav(floatBytes);
      expect(floatBuf.sampleRate, equals(48000));
      expect(floatBuf.numChannels, equals(2));
      expect(floatBuf.length, greaterThanOrEqualTo(480));

      final tmpDir = await Directory.systemTemp.createTemp('hum_wav_test_');
      try {
        final path = '${tmpDir.path}/test_pcm16.wav';
        final host2 = SyncAudioHost(context: context);
        final oscL2 = SineOscillator(frequency: const .value(440.0));
        final oscR2 = SineOscillator(frequency: const .value(880.0));
        host2.setGraph(root: Out.stereo(left: oscL2.outlet, right: oscR2.outlet));
        await host2.exportWav(
          path: path,
          duration: const Duration(milliseconds: 10),
          format: .pcm16,
        );
        await host2.dispose();
        final diskBuf = await loadWav(path);
        expect(diskBuf.sampleRate, equals(48000));
        expect(diskBuf.numChannels, equals(2));
        expect(diskBuf.length, equals(floatBuf.length));
        for (int i = 0; i < 64; i++) {
          expect(diskBuf[0][i], closeTo(floatBuf[0][i], 1e-3));
          expect(diskBuf[1][i], closeTo(floatBuf[1][i], 1e-3));
        }
      } finally {
        await tmpDir.delete(recursive: true);
      }

      await host.dispose();
    });

    test('decodes 24-bit PCM with odd-sized JUNK chunk and WAVE_FORMAT_EXTENSIBLE', () {
      // 2 frames mono: +0.5 (0x400000) and -0.5 (0xC00000).
      final pcm24 = Uint8List.fromList([
        0x00, 0x00, 0x40, // +0.5
        0x00, 0x00, 0xC0, // -0.5
      ]);
      final wav = _buildCustomWav(
        formatTag: 1,
        numChannels: 1,
        sampleRate: 44100,
        bitsPerSample: 24,
        pcmBytes: pcm24,
        includeJunkChunk: true,
        extensible: true,
      );
      final buf = readWav(wav);
      expect(buf.sampleRate, equals(44100));
      expect(buf.numChannels, equals(1));
      expect(buf.length, equals(2));
      expect(buf[0][0], closeTo(0.5, 1e-5));
      expect(buf[0][1], closeTo(-0.5, 1e-5));
    });

    test('throws FormatException on invalid WAV bytes', () {
      expect(() => readWav(Uint8List(4)), throwsFormatException);
      expect(
        () => readWav(Uint8List.fromList('NOTAWAVHEADER'.codeUnits)),
        throwsFormatException,
      );
    });

    test('exportWav preserves distinct blocks instead of repeating the last block', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);

      for (final useIsolate in [false, true]) {
        final host = useIsolate
            ? await IsolateAudioHost.spawn(context: context)
            : SyncAudioHost(context: context);
        try {
          // 100 Hz sine wave: period is 480 samples (7.5 blocks), so consecutive
          // 64-sample blocks must differ markedly.
          final osc = SineOscillator(frequency: const .value(100.0));
          host.setGraph(root: Out.mono(osc.outlet));

          final bytes = await host.exportWav(
            duration: const Duration(milliseconds: 10),
            format: .float32,
          );
          final buf = readWav(bytes);
          expect(buf.length, greaterThanOrEqualTo(256));

          // Block 0 starts near 0.0; block 2 (sample 128) is near +1.0.
          expect(buf[0][0], closeTo(0.0, 0.05));
          expect(buf[0][120], closeTo(1.0, 0.05));
          expect(buf[0][0], isNot(closeTo(buf[0][64], 0.1)));
        } finally {
          await host.dispose();
        }
      }
    });
  });

  group('SamplePlayer & Buffer Registry', () {
    test('plays one-shot mono buffer and stops cleanly at end', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 16);
      final host = SyncAudioHost(context: context);

      final samples = Float32List.fromList(
        List.generate(8, (i) => (i + 1) / 8.0),
      );
      final handle = host.loadBuffer(
        AudioBuffer.mono(samples, sampleRate: 48000),
      );

      final player = SamplePlayer(buffer: handle);
      expect(host.setGraph(root: Out.mono(player.outlet)), isEmpty);

      final blocks = await host.renderBlocks(1);
      final out = blocks[0];
      for (int i = 0; i < 8; i++) {
        expect(out[i], closeTo(samples[i], 1e-5));
      }
      for (int i = 8; i < 16; i++) {
        expect(out[i], equals(0.0));
      }

      await host.dispose();
    });

    test('loops seamlessly within [loopStart, loopEnd) and supports reverse rate', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 16);
      final host = SyncAudioHost(context: context);

      // Buffer: [0.0, 0.25, 0.5, 0.75, 1.0, 0.0]
      final handle = host.loadBuffer(
        AudioBuffer.mono(
          Float32List.fromList([0.0, 0.25, 0.5, 0.75, 1.0, 0.0]),
          sampleRate: 48000,
        ),
      );

      final player = SamplePlayer(
        buffer: handle,
        loop: true,
        loopStart: 1,
        loopEnd: 5, // [0.25, 0.5, 0.75, 1.0]
      );
      expect(host.setGraph(root: Out.mono(player.outlet)), isEmpty);

      final blocks = await host.renderBlocks(1);
      final out = blocks[0];
      final expected = [0.25, 0.5, 0.75, 1.0];
      for (int i = 0; i < 16; i++) {
        expect(out[i], closeTo(expected[i % 4], 1e-5));
      }

      // Switch to reverse playback (-1.0) in-place.
      host.update(player, (
        bufferId: null,
        rate: -1.0,
        loop: true,
        loopStart: 1,
        loopEnd: 5,
      ));
      final revBlocks = await host.renderBlocks(1);
      // Should walk backwards through [0.25, 0.5, 0.75, 1.0].
      expect(revBlocks[0][1], isNot(equals(revBlocks[0][0])));

      await host.dispose();
    });

    test('compensates automatically for buffer sampleRate vs context sampleRate', () async {
      // Buffer at 24 kHz played in a 48 kHz engine should step 0.5 frames/sample.
      const context = ProcessContext(sampleRate: 48000, vectorSize: 16);
      final host = SyncAudioHost(context: context);

      // 24 kHz sine at 1000 Hz -> period 24 samples.
      final bufSamples = Float32List(240);
      for (int i = 0; i < bufSamples.length; i++) {
        bufSamples[i] = math.sin(2.0 * math.pi * 1000.0 * i / 24000.0);
      }
      final handle = host.loadBuffer(
        AudioBuffer.mono(bufSamples, sampleRate: 24000),
      );

      final player = SamplePlayer(buffer: handle, loop: true);
      expect(host.setGraph(root: Out.mono(player.outlet)), isEmpty);

      final blocks = await host.renderBlocks(2);
      // At 48 kHz, sample 12 should be ~sin(2*pi*1000*12/48000) = sin(pi/2) = 1.0.
      expect(blocks[0][12], closeTo(1.0, 0.01));
      // Sample 24 (block 1 index 8) should be ~sin(pi) = 0.0.
      expect(blocks[1][8], closeTo(0.0, 0.01));

      await host.dispose();
    });

    test('retriggers on rising edge and swaps buffer in-place without graph rebuild', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 16);
      final host = SyncAudioHost(context: context);

      final bufA = host.loadBuffer(
        AudioBuffer.mono(Float32List.fromList([0.5, 0.5, 0.5, 0.5]), sampleRate: 48000),
      );
      final bufB = host.loadBuffer(
        AudioBuffer.mono(Float32List.fromList([-0.8, -0.8, -0.8, -0.8]), sampleRate: 48000),
      );

      // Clock fires a 1-sample trigger at sample 0.
      final clock = Clock.bpm(120.0);
      final player = SamplePlayer(
        buffer: bufA,
        trigger: clock.outlets[Clock.triggerOutlet],
      );
      expect(host.setGraph(root: Out.mono(player.outlet)), isEmpty);

      final procBefore = host.processorOf<SamplePlayerProcessor>(player);
      final blockA = (await host.renderBlocks(1))[0];
      expect(blockA[0], closeTo(0.5, 1e-5));
      expect(blockA[4], equals(0.0));

      // Declaratively swap bufA -> bufB via setGraph (same channel count):
      // processor instance must be preserved in-place!
      final playerB = SamplePlayer(
        buffer: bufB,
        trigger: clock.outlets[Clock.triggerOutlet],
      );
      expect(host.setGraph(root: Out.mono(playerB.outlet)), isEmpty);
      final procAfter = host.processorOf<SamplePlayerProcessor>(playerB);
      expect(identical(procBefore, procAfter), isTrue);

      await host.dispose();
    });

    test('transfers stereo buffers cleanly across IsolateAudioHost and falls back to silence on unload', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 16);
      final host = await IsolateAudioHost.spawn(context: context);

      final left = Float32List.fromList(List.filled(32, 0.25));
      final right = Float32List.fromList(List.filled(32, -0.75));
      final original = AudioBuffer.stereo(left, right, sampleRate: 48000);

      final handle = host.loadBuffer(original);

      // Original host-side AudioBuffer remains intact for UI waveform display.
      expect(original[0][0], closeTo(0.25, 1e-6));
      expect(original[1][0], closeTo(-0.75, 1e-6));

      final player = SamplePlayer(buffer: handle, loop: true);
      expect(
        host.setGraph(root: Out.stereo(left: player.left, right: player.right)),
        isEmpty,
      );

      final blocks = await host.renderBlocks(1);
      expect(blocks, hasLength(2)); // L, R
      expect(blocks[0][0], closeTo(0.25, 1e-5));
      expect(blocks[1][0], closeTo(-0.75, 1e-5));

      // Unload buffer -> processor falls back to silence without crashing.
      host.unloadBuffer(handle);
      final silentBlocks = await host.renderBlocks(1);
      expect(silentBlocks[0][0], equals(0.0));
      expect(silentBlocks[1][0], equals(0.0));

      await host.dispose();
    });
  });
}
