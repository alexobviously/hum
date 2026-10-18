import 'dart:typed_data';

import 'package:dsp/dsp.dart';
import 'package:test/test.dart';

void main() {
  group('Saturator node', () {
    test('declares expected inlets and outlets for mono and stereo', () {
      final oscA = SineOscillator(frequency: const .value(440));
      final oscB = SineOscillator(frequency: const .value(880));

      final mono = Saturator.mono(oscA.outlet);
      expect(mono.inlets.length, equals(4)); // drive, bias, mix, audio
      expect(mono.inlets[Saturator.driveInlet].source, isNull);
      expect(mono.inlets[Saturator.biasInlet].source, isNull);
      expect(mono.inlets[Saturator.mixInlet].source, isNull);
      expect(mono.inlets[Saturator.audioInletOffset].source, equals(oscA.outlet));
      expect(mono.outlets.length, equals(1));

      final stereo = Saturator.stereo(oscA.outlet, oscB.outlet);
      expect(stereo.inlets.length, equals(5)); // drive, bias, mix, audioL, audioR
      expect(stereo.inlets[Saturator.audioInletOffset].source, equals(oscA.outlet));
      expect(stereo.inlets[Saturator.audioInletOffset + 1].source, equals(oscB.outlet));
      expect(stereo.outlets.length, equals(2));
      expect(stereo.left, equals(stereo.outlets[0]));
      expect(stereo.right, equals(stereo.outlets[1]));
    });

    test('processor shapes tanh curve smoothly', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = SaturatorProcessor(
        numChannels: 1,
        drive: 1.0,
        bias: 0.0,
        mix: 1.0,
        mode: SaturationMode.tanh,
      );

      final inBuf = Float32List.fromList([0.0, 1.0, -1.0, 10.0]);
      final outBuf = Float32List(4);

      processor.process(context, [inBuf], [outBuf]);

      expect(outBuf[0], closeTo(0.0, 1e-5));
      // tanh(1.0) ≈ 0.761594
      expect(outBuf[1], closeTo(0.761594, 1e-4));
      // Odd symmetry: tanh(-1.0) == -tanh(1.0)
      expect(outBuf[2], closeTo(-0.761594, 1e-4));
      // Saturation ceiling near 1.0
      expect(outBuf[3], closeTo(1.0, 1e-3));
    });

    test('processor shapes cubic curve with zero corner derivative', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 5);
      final processor = SaturatorProcessor(
        numChannels: 1,
        drive: 1.0,
        bias: 0.0,
        mix: 1.0,
        mode: SaturationMode.cubic,
      );

      final inBuf = Float32List.fromList([0.0, 0.5, 1.0, 2.0, -2.0]);
      final outBuf = Float32List(5);

      processor.process(context, [inBuf], [outBuf]);

      expect(outBuf[0], closeTo(0.0, 1e-5));
      // cubic(0.5) = 0.5 * (1.5 - 0.5 * 0.25) = 0.5 * 1.375 = 0.6875
      expect(outBuf[1], closeTo(0.6875, 1e-4));
      // cubic(1.0) = 1.0 * (1.5 - 0.5) = 1.0
      expect(outBuf[2], closeTo(1.0, 1e-5));
      // Beyond 1.0 is smoothly clamped to 1.0
      expect(outBuf[3], equals(1.0));
      expect(outBuf[4], equals(-1.0));
    });

    test('processor shapes algebraic and atan curves', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 3);

      final algProc = SaturatorProcessor(
        numChannels: 1,
        mode: SaturationMode.algebraic,
      );
      final atanProc = SaturatorProcessor(
        numChannels: 1,
        mode: SaturationMode.atan,
      );

      final inBuf = Float32List.fromList([0.0, 1.0, 50.0]);
      final outAlg = Float32List(3);
      final outAtan = Float32List(3);

      algProc.process(context, [inBuf], [outAlg]);
      atanProc.process(context, [inBuf], [outAtan]);

      // 0 in -> 0 out
      expect(outAlg[0], closeTo(0.0, 1e-5));
      expect(outAtan[0], closeTo(0.0, 1e-5));

      // 1.0 in -> 1/sqrt(2) ≈ 0.7071
      expect(outAlg[1], closeTo(0.707106, 1e-4));

      // Asymptotic limit approaches 1.0
      expect(outAlg[2], closeTo(0.9998, 1e-3));
      expect(outAtan[2], closeTo(0.987, 1e-2));
    });

    test('processor wavefolding inverts peaks past ceiling', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = SaturatorProcessor(
        numChannels: 1,
        mode: SaturationMode.wavefold,
      );

      // sin((pi/2) * x):
      // x = 0 -> sin(0) = 0
      // x = 1 -> sin(pi/2) = 1
      // x = 2 -> sin(pi) = 0 (folded down)
      // x = 3 -> sin(3pi/2) = -1 (folded to negative peak)
      final inBuf = Float32List.fromList([0.0, 1.0, 2.0, 3.0]);
      final outBuf = Float32List(4);

      processor.process(context, [inBuf], [outBuf]);

      expect(outBuf[0], closeTo(0.0, 1e-5));
      expect(outBuf[1], closeTo(1.0, 1e-4));
      expect(outBuf[2], closeTo(0.0, 1e-4));
      expect(outBuf[3], closeTo(-1.0, 1e-4));
    });

    test('asymmetric bias injects even harmonic asymmetry with zero DC offset on silence', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 3);
      final processor = SaturatorProcessor(
        numChannels: 1,
        drive: 1.0,
        bias: 0.4,
        mode: SaturationMode.tanh,
      );

      final inBuf = Float32List.fromList([0.0, 0.5, -0.5]);
      final outBuf = Float32List(3);

      processor.process(context, [inBuf], [outBuf]);

      // Zero input MUST produce zero output (DC correction)
      expect(outBuf[0], closeTo(0.0, 1e-6));

      // Asymmetry check: positive deflection and negative deflection must differ
      final posDeflection = outBuf[1];
      final negDeflection = outBuf[2].abs();
      expect(posDeflection, isNot(closeTo(negDeflection, 1e-3)));
    });

    test('mix parameter blends smoothly between dry and wet', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 1);
      final inBuf = Float32List.fromList([0.5]);
      final outBuf = Float32List(1);

      // 100% dry (mix = -1.0)
      final dryProc = SaturatorProcessor(
        numChannels: 1,
        drive: 5.0,
        mix: -1.0,
        mode: SaturationMode.tanh,
      );
      dryProc.process(context, [inBuf], [outBuf]);
      expect(outBuf[0], closeTo(0.5, 1e-5));

      // 100% wet (mix = 1.0)
      final wetProc = SaturatorProcessor(
        numChannels: 1,
        drive: 5.0,
        mix: 1.0,
        mode: SaturationMode.tanh,
      );
      wetProc.process(context, [inBuf], [outBuf]);
      final wetVal = outBuf[0];
      // tanh(0.5 * 5.0) = tanh(2.5) ≈ 0.9866
      expect(wetVal, closeTo(0.9866, 1e-3));

      // 50/50 mix (mix = 0.0)
      final midProc = SaturatorProcessor(
        numChannels: 1,
        drive: 5.0,
        mix: 0.0,
        mode: SaturationMode.tanh,
      );
      midProc.process(context, [inBuf], [outBuf]);
      expect(outBuf[0], closeTo(0.5 * 0.5 + wetVal * 0.5, 1e-4));
    });

    test('tube and tape convenience factories set expected defaults', () {
      final osc = SineOscillator(frequency: const .value(440));

      final tube = Saturator.tube(osc.outlet);
      expect(tube.mode, equals(SaturationMode.cubic));
      expect(tube.drive.valueOrNull, equals(2.0));
      expect(tube.bias.valueOrNull, equals(0.3));

      final tape = Saturator.tape(osc.outlet);
      expect(tape.mode, equals(SaturationMode.tanh));
      expect(tape.drive.valueOrNull, equals(1.5));
      expect(tape.bias.valueOrNull, equals(0.0));
    });

    test('.saturate() extension creates configured Saturator node', () {
      final osc = SineOscillator(frequency: const .value(440));
      final sat = osc.outlet.saturate(
        drive: const .value(3.0),
        mode: SaturationMode.atan,
      );

      expect(sat, isA<Saturator>());
      expect(sat.mode, equals(SaturationMode.atan));
      expect(sat.drive.valueOrNull, equals(3.0));
      expect(sat.inlets[Saturator.audioInletOffset].source, equals(osc.outlet));
    });

    test('compiles and executes inside AudioPipeline with live updates', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
      final saw = SawtoothOscillator(frequency: const .value(100));
      final sat = Saturator.mono(saw.outlet, drive: const .value(1.0));
      final pipeline = compilePipeline(root: sat, context: context);

      pipeline.process();
      final out1 = pipeline.outputs[0];
      expect(out1.any((s) => s != 0.0), isTrue);

      // Live parameter update
      final updated = Saturator.mono(
        saw.outlet,
        drive: const .value(10.0),
        bias: const .value(0.2),
        mode: SaturationMode.cubic,
      );
      pipeline.update(sat, updated);

      pipeline.process();
      final out2 = pipeline.outputs[0];
      expect(out2.any((s) => s != 0.0), isTrue);
    });

    test('handles dynamic audio-rate modulation of drive and bias', () {
      final context = ProcessContext(sampleRate: 44100, vectorSize: 4);
      final processor = SaturatorProcessor(
        numChannels: 1,
        mode: SaturationMode.cubic,
        isDriveSignal: true,
        isBiasSignal: true,
      );

      final driveBuf = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
      final biasBuf = Float32List.fromList([0.0, 0.1, 0.2, 0.3]);
      final mixBuf = Float32List(0);
      final audioBuf = Float32List.fromList([0.2, 0.2, 0.2, 0.2]);
      final outBuf = Float32List(4);

      final inputs = [driveBuf, biasBuf, mixBuf, audioBuf];
      processor.process(context, inputs, [outBuf]);

      // With increasing drive and bias across the block, the output should progressively saturate
      expect(outBuf[0], isNot(equals(outBuf[3])));
      expect(outBuf.every((s) => s.isFinite), isTrue);
    });
  });
}
