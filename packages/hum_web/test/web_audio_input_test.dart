@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:hum/hum.dart';
import 'package:hum_web/hum_web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  group('WebAudioInput & WebAudioInputDriver (browser)', () {
    test(
      'captures multi-channel audio through AudioWorklet into hum In node',
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

        // Build a stereo source with distinct L (440 Hz) and R (880 Hz) sines
        final oscL = offlineCtx.createOscillator()
          ..frequency.value = 440.0;
        final oscR = offlineCtx.createOscillator()
          ..frequency.value = 880.0;
        final merger = offlineCtx.createChannelMerger(2);
        oscL.connect(merger, 0, 0);
        oscR.connect(merger, 0, 1);
        oscL.start();
        oscR.start();

        final input = WebAudioInput(
          numChannels: 2,
          vectorSize: vectorSize,
          bufferFrames: 2048,
          audioContext: offlineCtx,
          sourceNode: merger,
        );

        final driver = input.createDriver() as WebAudioInputDriver;
        await driver.start(context);
        expect(driver.isOpen, isTrue);
        expect(driver.sampleRate, equals(sampleRate));

        // Render offline so the capture worklet posts blocks over MessagePort
        await offlineCtx.startRendering().toDart;
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(driver.availableReadFrames, greaterThanOrEqualTo(vectorSize));

        // Wire into a hum AudioEngine with In.stereo() -> Mult(0.5) -> Out
        final mic = In.stereo();
        final scaledL = Mult.mono(
          input: mic.left,
          value: const .value(0.5),
          interpTime: 0.0,
        );
        final scaledR = Mult.mono(
          input: mic.right,
          value: const .value(0.5),
          interpTime: 0.0,
        );
        final host = AudioHost.sync(context: context) as SyncAudioHost;
        expect(
          host.setGraph(
            root: Out.stereo(left: scaledL.outlet, right: scaledR.outlet),
          ),
          isEmpty,
        );

        host.engine.configureInputs(2);
        driver.read(host.engine.inputs);
        host.process();

        final outL = host.outputs[0];
        final outR = host.outputs[1];
        double maxAbsL = 0.0;
        double maxAbsR = 0.0;
        double maxDiff = 0.0;
        for (int i = 0; i < vectorSize; i++) {
          final l = outL[i].abs();
          final r = outR[i].abs();
          final diff = (outL[i] - outR[i]).abs();
          if (l > maxAbsL) maxAbsL = l;
          if (r > maxAbsR) maxAbsR = r;
          if (diff > maxDiff) maxDiff = diff;
        }

        // Non-silent, scaled by 0.5, and L != R (proving discrete stereo capture)
        expect(maxAbsL, greaterThan(0.25));
        expect(maxAbsL, lessThanOrEqualTo(0.51));
        expect(maxAbsR, greaterThan(0.25));
        expect(maxAbsR, lessThanOrEqualTo(0.51));
        expect(maxDiff, greaterThan(0.1));

        await driver.close();
        await host.dispose();
        expect(driver.isClosed, isTrue);
        expect(driver.isOpen, isFalse);
      },
    );

    test(
      'can reuse the same BaseAudioContext across multiple capture sessions',
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
        final osc = offlineCtx.createOscillator();

        final input = WebAudioInput(
          numChannels: 1,
          vectorSize: vectorSize,
          bufferFrames: 512,
          audioContext: offlineCtx,
          sourceNode: osc,
        );

        final driver1 = input.createDriver() as WebAudioInputDriver;
        await driver1.start(context);
        await driver1.close();

        final driver2 = input.createDriver() as WebAudioInputDriver;
        await driver2.start(context);
        expect(driver2.isOpen, isTrue);
        await driver2.close();
      },
    );
  });
}
