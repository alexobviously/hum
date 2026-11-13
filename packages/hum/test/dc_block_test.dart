import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('DCBlock node & DcBlockMixin', () {
    test('declares expected inlets and outlets for mono, stereo, and multi-channel', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));
      final oscC = SineOscillator(frequency: const .value(220));

      final mono = DCBlock.mono(oscA.outlet);
      expect(mono.inlets.length, equals(1));
      expect(mono.inlets[0].source, equals(oscA.outlet));
      expect(mono.outlets.length, equals(1));

      final stereo = DCBlock.stereo(oscA.outlet, oscB.outlet);
      expect(stereo.inlets.length, equals(2));
      expect(stereo.outlets.length, equals(2));
      expect(stereo.left, equals(stereo.outlets[0]));
      expect(stereo.right, equals(stereo.outlets[1]));

      final quad = DCBlock(channels: [oscA.outlet, oscB.outlet, oscC.outlet]);
      expect(quad.inlets.length, equals(3));
      expect(quad.outlets.length, equals(3));
    });

    test('decays pure constant DC offset to zero', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 512);
      final processor = DCBlockProcessor(numChannels: 1, cutoffHz: 10.0);

      final inBuf = Float32List(512)..fillRange(0, 512, 1.0); // Constant 1.0 DC
      final outBuf = Float32List(512);

      // Process several blocks to let the filter decay
      for (int b = 0; b < 20; b++) {
        processor.process(context, [inBuf], [outBuf]);
      }

      // After ~10,000 samples at 44.1kHz with a 10Hz cutoff, 1.0 DC should decay to near 0.0
      expect(outBuf[511].abs(), lessThan(0.05));
    });

    test('preserves audible AC frequencies without attenuation', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final processor = DCBlockProcessor(numChannels: 1, cutoffHz: 5.0);

      final inBuf = Float32List(64);
      final outBuf = Float32List(64);
      double phase = 0.0;
      final phaseInc = 2.0 * math.pi * 1000.0 / 44100.0;

      // Process continuous 1000 Hz sine wave across several blocks
      for (int b = 0; b < 20; b++) {
        for (int i = 0; i < 64; i++) {
          inBuf[i] = math.sin(phase);
          phase += phaseInc;
        }
        processor.process(context, [inBuf], [outBuf]);
      }

      // Peak amplitude at 1000 Hz should remain ~1.0 (+/- 1%)
      double maxAmp = 0.0;
      for (int i = 0; i < 64; i++) {
        maxAmp = math.max(maxAmp, outBuf[i].abs());
      }
      expect(maxAmp, closeTo(1.0, 0.01));
    });

    test('handles independent multi-channel state without crosstalk', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 256);
      final processor = DCBlockProcessor(numChannels: 2, cutoffHz: 20.0);

      final inL = Float32List(256)..fillRange(0, 256, 1.0); // +1.0 DC on Left
      final inR = Float32List(256)..fillRange(0, 256, -1.0); // -1.0 DC on Right
      final outL = Float32List(256);
      final outR = Float32List(256);

      for (int b = 0; b < 10; b++) {
        processor.process(context, [inL, inR], [outL, outR]);
      }

      // Both channels should decay towards zero from their respective polarities
      expect(outL[255], greaterThan(0.0));
      expect(outL[255], lessThan(0.1));

      expect(outR[255], lessThan(0.0));
      expect(outR[255], greaterThan(-0.1));
    });

    test('.dcBlock() extension syntax creates DCBlock node', () {
      final osc = SineOscillator(frequency: const .value(440));
      final blocked = osc.outlet.dcBlock(cutoffHz: 8.0);

      expect(blocked, isA<DCBlock>());
      expect(blocked.cutoffHz, equals(8.0));
      expect(blocked.inlets[0].source, equals(osc.outlet));
    });

    test('compiles and executes inside AudioPipeline with live updates', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final saw = SawtoothOscillator(frequency: const .value(100));
      final dcBlock = DCBlock.mono(saw.outlet);
      final pipeline = compilePipeline(
        root: dcBlock,
        context: context,
      ).pipeline!;
      pipeline.process();
      final out = pipeline.outputs[0];
      expect(out.any((s) => s != 0.0), isTrue);

      // Live parameter update
      pipeline.update(dcBlock, DCBlock.mono(saw.outlet, cutoffHz: 10.0));
      pipeline.process();
      expect(pipeline.outputs[0].any((s) => s != 0.0), isTrue);
    });

    test('Saturator with dcBlock=true strips asymmetric tube DC drift', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 512);

      // Heavy asymmetric saturation
      final satWithDc = SaturatorProcessor(
        numChannels: 1,
        drive: 5.0,
        bias: 0.8,
        mode: SaturationMode.cubic,
        dcBlock: false,
      );
      final satWithBlock = SaturatorProcessor(
        numChannels: 1,
        drive: 5.0,
        bias: 0.8,
        mode: SaturationMode.cubic,
        dcBlock: true,
      );

      final inBuf = Float32List(512);
      for (int i = 0; i < 512; i++) {
        inBuf[i] = math.sin(2.0 * math.pi * 100.0 * i / 44100.0);
      }
      final outNoBlock = Float32List(512);
      final outBlock = Float32List(512);

      final inSaturator = [
        Float32List(0),
        Float32List(0),
        Float32List(0),
        inBuf,
      ];

      for (int b = 0; b < 20; b++) {
        satWithDc.process(context, inSaturator, [outNoBlock]);
        satWithBlock.process(context, inSaturator, [outBlock]);
      }

      // Compute average (DC bias) across the block
      double meanNoBlock = 0.0;
      double meanBlock = 0.0;
      for (int i = 0; i < 512; i++) {
        meanNoBlock += outNoBlock[i];
        meanBlock += outBlock[i];
      }
      meanNoBlock /= 512;
      meanBlock /= 512;

      // The DC blocked version should have significantly lower mean DC drift
      expect(meanBlock.abs(), lessThan(meanNoBlock.abs()));
    });
  });
}
