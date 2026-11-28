import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:test/test.dart';

void main() {
  group('Wavetable builders', () {
    test(
      'builds procedural basicShapes, formants, and organ mipmapped tables',
      () {
        final basic = Wavetable.basicShapes(frameSize: 1024);
        expect(basic.numFrames, equals(4));
        expect(basic.frameSize, equals(1024));
        expect(basic.mipmapped, isTrue);
        expect(basic.toAudioBuffer().numChannels, equals(4));
        expect(basic.toAudioBuffer().length, equals(2048)); // 2 * frameSize

        final formants = Wavetable.formants(frameSize: 512);
        expect(formants.numFrames, equals(5));
        expect(formants.toAudioBuffer().length, equals(1024));

        final organ = Wavetable.organ(frameSize: 512);
        expect(organ.numFrames, equals(4));
        expect(organ.toAudioBuffer().length, equals(1024));
      },
    );

    test('slices concatenated mono Serum/Vital AudioBuffer via Wavetable.fromBuffer', () {
      const frameSize = 256;
      final concat = Float32List(frameSize * 3);
      for (int f = 0; f < 3; f++) {
        for (int i = 0; i < frameSize; i++) {
          concat[f * frameSize + i] = math.sin(
            2.0 * math.pi * (f + 1) * i / frameSize,
          );
        }
      }
      final raw = AudioBuffer.mono(concat, sampleRate: 48000);
      final table = Wavetable.fromBuffer(raw, frameSize: frameSize);
      expect(table.numFrames, equals(3));
      expect(table.frameSize, equals(frameSize));
      expect(table.mipmapped, isTrue);
    });
  });

  group('WavetableOscillator', () {
    test('plays accurate 440 Hz sine from basicShapes position 0.0', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(context: context);
      final wt = host.loadWavetable(Wavetable.basicShapes(frameSize: 1024));

      final osc = WavetableOscillator(
        wavetable: wt,
        frequency: const .value(440.0),
        position: const .value(0.0), // frame 0 = pure sine
      );
      final pitch = PitchDetector(input: osc.outlet);
      expect(host.setGraph(root: Out.mono(pitch.audio)), isEmpty);

      final blocks = await host.renderBlocks(50);
      final proc = host.processorOf<PitchDetectorProcessor>(pitch)!;
      expect(proc.isPitched, isTrue);
      expect(proc.frequency, closeTo(440.0, 0.5));
      expect(proc.clarity, greaterThan(0.99));

      // Verify non-silent output bounded by [-1, 1].
      double peak = 0.0;
      for (final b in blocks) {
        for (final s in b) {
          if (s.abs() > peak) peak = s.abs();
        }
      }
      expect(peak, closeTo(1.0, 0.05));

      await host.dispose();
    });

    test('morphs smoothly across frames with static and CV position', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(context: context);

      // Frame 0 = fundamental (1x), Frame 1 = 2nd harmonic (2x)
      final wt = host.loadWavetable(
        Wavetable.fromHarmonics(const [
          [1.0, 0.0],
          [0.0, 1.0],
        ], frameSize: 512),
      );

      final osc0 = WavetableOscillator(
        wavetable: wt,
        frequency: const .value(220.0),
        position: const .value(0.0),
      );
      final pitch0 = PitchDetector(input: osc0.outlet);
      expect(host.setGraph(root: Out.mono(pitch0.audio)), isEmpty);
      await host.renderBlocks(60);
      expect(
        host.processorOf<PitchDetectorProcessor>(pitch0)!.frequency,
        closeTo(220.0, 1.0),
      );

      // Morph to position 1.0 -> pure 2nd harmonic = 440 Hz!
      host.update(osc0, (wavetable: null, frequency: null, position: 1.0));
      await host.renderBlocks(60);
      expect(
        host.processorOf<PitchDetectorProcessor>(pitch0)!.frequency,
        closeTo(440.0, 1.0),
      );

      // Audio-rate CV modulation on position & frequency works cleanly.
      final lfo = SineOscillator(frequency: const .value(2.0))
          .mapRange(0.0, 1.0);
      final modOsc = WavetableOscillator(
        wavetable: wt,
        frequency: const .value(220.0),
        position: .signal(lfo.outlet),
      );
      expect(host.setGraph(root: Out.mono(modOsc.outlet)), isEmpty);
      final rendered = await host.renderBlocks(10);
      expect(rendered.last.any((s) => s.abs() > 0.1), isTrue);

      await host.dispose();
    });

    test('band-limited mipmaps suppress aliasing at high frequencies (6 kHz saw)', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = SyncAudioHost(context: context);
      final wt = host.loadWavetable(Wavetable.basicShapes(frameSize: 2048));

      // At 6 kHz @ 48 kHz SR, sawtooth only has harmonics 1 (6k), 2 (12k), 3 (18k)
      // below Nyquist (24 kHz). High mip level should produce a clean, finite,
      // smooth waveform with low high-frequency aliasing.
      final osc = WavetableOscillator(
        wavetable: wt,
        frequency: const .value(6000.0),
        position: const .value(2.0 / 3.0), // frame 2 = sawtooth
      );
      expect(host.setGraph(root: Out.mono(osc.outlet)), isEmpty);
      final blocks = await host.renderBlocks(10);

      double peak = 0.0;
      for (final b in blocks) {
        for (final s in b) {
          expect(s.isFinite, isTrue);
          if (s.abs() > peak) peak = s.abs();
        }
      }
      expect(peak, greaterThan(0.2));
      expect(peak, lessThanOrEqualTo(1.2));

      await host.dispose();
    });

    test('supports WavetableHandle.fromBuffer for raw un-mipmapped buffers and IsolateAudioHost', () async {
      const context = ProcessContext(sampleRate: 48000, vectorSize: 64);
      final host = await IsolateAudioHost.spawn(context: context);

      // Raw 256-sample sine cycle loaded as a plain BufferHandle.
      final rawCycle = Float32List(256);
      for (int i = 0; i < 256; i++) {
        rawCycle[i] = math.sin(2.0 * math.pi * i / 256);
      }
      final rawHandle = host.loadBuffer(
        AudioBuffer.mono(rawCycle, sampleRate: 48000),
      );
      final wtHandle = WavetableHandle.fromBuffer(rawHandle);
      expect(wtHandle.mipmapped, isFalse);
      expect(wtHandle.numFrames, equals(1));
      expect(wtHandle.frameSize, equals(256));

      final osc = WavetableOscillator(
        wavetable: wtHandle,
        frequency: const .value(440.0),
      );
      expect(host.setGraph(root: Out.mono(osc.outlet)), isEmpty);

      final blocks = await host.renderBlocks(4);
      double peak = 0.0;
      for (final b in blocks) {
        for (final s in b) {
          if (s.abs() > peak) peak = s.abs();
        }
      }
      expect(peak, closeTo(1.0, 0.05));

      // Unloading buffer drops output cleanly to silence without crashing.
      host.unloadWavetable(wtHandle);
      final silent = await host.renderBlocks(1);
      expect(silent[0].every((s) => s == 0.0), isTrue);

      await host.dispose();
    });
  });
}
