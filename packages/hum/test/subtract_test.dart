import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('Subtract node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final mono = Subtract.mono(input: oscA.outlet, value: const .value(0.5));
      expect(mono.inlets.length, equals(2));
      expect(mono.inlets[Subtract.valueInlet].source, isNull);
      expect(
        mono.inlets[Subtract.audioInletOffset].source,
        equals(oscA.outlet),
      );
      expect(mono.outlets.length, equals(1));

      final stereo = Subtract.stereo(
        leftInput: oscA.outlet,
        rightInput: oscB.outlet,
        value: ControlParam.signal(oscB.outlet),
      );
      expect(stereo.inlets.length, equals(3));
      expect(stereo.inlets[Subtract.valueInlet].source, equals(oscB.outlet));
      expect(
        stereo.inlets[Subtract.audioInletOffset].source,
        equals(oscA.outlet),
      );
      expect(
        stereo.inlets[Subtract.audioInletOffset + 1].source,
        equals(oscB.outlet),
      );
      expect(stereo.outlets.length, equals(2));
      expect(stereo.left, equals(stereo.outlets[0]));
      expect(stereo.right, equals(stereo.outlets[1]));
    });

    test('subtracts constant scalar offset', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = SubtractProcessor(value: 0.25, numChannels: 1);

      final inBuf = Float32List.fromList([1.0, 0.5, 0.0, -0.5]);
      final outBuf = Float32List(4);

      processor.process(
        context,
        [Float32List(4), inBuf],
        [outBuf],
      );

      expect(outBuf[0], closeTo(0.75, 1e-6));
      expect(outBuf[1], closeTo(0.25, 1e-6));
      expect(outBuf[2], closeTo(-0.25, 1e-6));
      expect(outBuf[3], closeTo(-0.75, 1e-6));
    });

    test('subtracts audio-rate vector signal', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = SubtractProcessor(value: null, numChannels: 1);

      final valBuf = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);
      final inBuf = Float32List.fromList([1.0, 1.0, 1.0, 1.0]);
      final outBuf = Float32List(4);

      processor.process(
        context,
        [valBuf, inBuf],
        [outBuf],
      );

      expect(outBuf[0], closeTo(0.9, 1e-6));
      expect(outBuf[1], closeTo(0.8, 1e-6));
      expect(outBuf[2], closeTo(0.7, 1e-6));
      expect(outBuf[3], closeTo(0.6, 1e-6));
    });

    test(
      'operator - syntax creates Subtract node and cancels identical signals',
      () {
        final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
        final saw = SawtoothOscillator(frequency: const .value(220));

        // S - S == 0
        final difference = saw.outlet - saw.outlet;
        expect(difference.node, isA<Subtract>());

        final pipeline = compilePipeline(
          root: difference.node,
          context: context,
        ).pipeline!;
        pipeline.process();

        final output = pipeline.outputs[0];
        for (int i = 0; i < 64; i++) {
          expect(output[i], closeTo(0.0, 1e-6));
        }
      },
    );

    test('.subtract() extension subtracts scalar offset', () {
      final osc = SineOscillator(frequency: const .value(440));
      final sub = osc.outlet.subtract(0.5);

      expect(sub, isA<Subtract>());
      expect(sub.params.value, equals(0.5));
      expect(sub.inlets[Subtract.audioInletOffset].source, equals(osc.outlet));
    });

    test('compiles and executes inside AudioPipeline with live updates', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final osc = SineOscillator(frequency: const .value(440));
      final sub = Subtract.mono(input: osc.outlet, value: const .value(0.5));

      final pipeline = compilePipeline(root: sub, context: context).pipeline!;
      pipeline.process();

      final out1 = pipeline.outputs[0];
      expect(out1.any((s) => s != 0.0), isTrue);

      // Live update to subtract 10.0
      final updated = Subtract.mono(
        input: osc.outlet,
        value: const .value(10.0),
      );
      pipeline.update(sub, updated);

      pipeline.process();
      final out2 = pipeline.outputs[0];
      // Since sine is in [-1, 1], subtracting 10 puts it in [-11, -9]
      expect(out2.every((s) => s <= -9.0 && s >= -11.0), isTrue);
    });
  });
}
