@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:hum/hum.dart';
import 'package:hum_web/hum_web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  group('WebAudioOutput & WebAudioOutputDriver (browser)', () {
    test(
      'renders hum SineOscillator audio through AudioWorklet in OfflineAudioContext',
      () async {
        const sampleRate = 44100;
        const vectorSize = 128;
        const totalFrames = 1024;
        final context = ProcessContext(
          sampleRate: sampleRate,
          vectorSize: vectorSize,
        );

        final offlineCtx = web.OfflineAudioContext(
          2.toJS,
          totalFrames,
          sampleRate.toDouble(),
        );

        final output = WebAudioOutput(
          numChannels: 2,
          vectorSize: vectorSize,
          bufferFrames: 2048,
          audioContext: offlineCtx,
        );

        final driver = output.createDriver() as WebAudioOutputDriver;
        await driver.start(context);
        expect(driver.isOpen, isTrue);
        expect(driver.sampleRate, equals(sampleRate));

        final osc = SineOscillator(frequency: const .value(440.0));
        final out = Out.stereo(left: osc.outlet, right: osc.outlet);
        final host = AudioHost.sync(context: context) as SyncAudioHost;
        expect(host.setGraph(root: out), isEmpty);

        // Pre-fill ring buffer with 8 blocks (1024 frames)
        for (int i = 0; i < totalFrames ~/ vectorSize; i++) {
          host.process();
          driver.write(host.outputs);
        }

        // Allow MessagePort audio chunks to reach the worklet before rendering
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final rendered = await offlineCtx.startRendering().toDart;
        expect(rendered.numberOfChannels, equals(2));
        expect(rendered.length, equals(totalFrames));

        final leftData = rendered.getChannelData(0).toDart;
        final rightData = rendered.getChannelData(1).toDart;

        double maxAbsL = 0.0;
        double maxAbsR = 0.0;
        for (int i = 0; i < totalFrames; i++) {
          final l = leftData[i].abs();
          final r = rightData[i].abs();
          if (l > maxAbsL) maxAbsL = l;
          if (r > maxAbsR) maxAbsR = r;
        }

        expect(maxAbsL, greaterThan(0.5));
        expect(maxAbsR, greaterThan(0.5));

        await driver.close();
        await host.dispose();
        expect(driver.isClosed, isTrue);
        expect(driver.isOpen, isFalse);
      },
    );

    test(
      'can reuse the same BaseAudioContext across multiple driver sessions',
      () async {
        const sampleRate = 44100;
        const vectorSize = 128;
        final context = ProcessContext(
          sampleRate: sampleRate,
          vectorSize: vectorSize,
        );

        final offlineCtx = web.OfflineAudioContext(
          1.toJS,
          256,
          sampleRate.toDouble(),
        );

        final output = WebAudioOutput(
          numChannels: 1,
          vectorSize: vectorSize,
          bufferFrames: 512,
          audioContext: offlineCtx,
        );

        final driver1 = output.createDriver() as WebAudioOutputDriver;
        await driver1.start(context);
        await driver1.close();

        // Second start on the same AudioContext must not fail on duplicate registerProcessor
        final driver2 = output.createDriver() as WebAudioOutputDriver;
        await driver2.start(context);
        expect(driver2.isOpen, isTrue);
        await driver2.close();
      },
    );
  });
}
