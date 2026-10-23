import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  test('dsp library exports core symbols and builds simple graph', () {
    final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
    final sine = SineOscillator(frequency: .value(440));
    final mult = Mult.mono(value: .value(0.8), input: sine.outlet);
    final pipeline = compilePipeline(root: mult, context: context).pipeline!;
    expect(pipeline.numChannels, equals(1));
    pipeline.process();
    expect(pipeline.outputs[0].length, equals(64));
  });

  test('square oscillator supports raw and PolyBLEP waveforms', () {
    final context = ProcessContext(sampleRate: 8, vectorSize: 4);
    final rawOutput = Float32List(4);
    final correctedOutput = Float32List(4);

    SquareOscillatorProcessor(
      frequency: 2,
      usePolyBlep: false,
    ).process(context, [], [rawOutput]);
    SquareOscillatorProcessor(frequency: 2, usePolyBlep: true).process(
      context,
      [],
      [correctedOutput],
    );

    expect(rawOutput, equals([1.0, 1.0, -1.0, -1.0]));
    expect(correctedOutput[0], closeTo(0.0, 1e-6));
    expect(correctedOutput[2], closeTo(0.0, 1e-6));
  });

  test('sawtooth oscillator supports raw and PolyBLEP waveforms', () {
    final context = ProcessContext(sampleRate: 8, vectorSize: 4);
    final rawOutput = Float32List(4);
    final correctedOutput = Float32List(4);

    SawtoothOscillatorProcessor(
      frequency: 2,
      usePolyBlep: false,
    ).process(context, [], [rawOutput]);
    SawtoothOscillatorProcessor(frequency: 2, usePolyBlep: true).process(
      context,
      [],
      [correctedOutput],
    );

    expect(rawOutput, equals([-1.0, -0.5, 0.0, 0.5]));
    expect(correctedOutput[0], closeTo(0.0, 1e-6));
    expect(correctedOutput[1], closeTo(-0.5, 1e-6));
  });

  test('triangle oscillator supports raw and PolyBLEP waveforms', () {
    final context = ProcessContext(sampleRate: 8, vectorSize: 4);
    final rawOutput = Float32List(4);
    final correctedOutput = Float32List(4);

    TriangleOscillatorProcessor(
      frequency: 2,
      usePolyBlep: false,
    ).process(context, [], [rawOutput]);
    TriangleOscillatorProcessor(frequency: 2, usePolyBlep: true).process(
      context,
      [],
      [correctedOutput],
    );

    expect(rawOutput, equals([0.0, 1.0, 0.0, -1.0]));
    expect(correctedOutput[0], closeTo(0.0, 1e-6));
    expect(correctedOutput[1], closeTo(2.0 / 3.0, 1e-6));
    expect(correctedOutput[2], closeTo(0.0, 1e-6));
    expect(correctedOutput[3], closeTo(-2.0 / 3.0, 1e-6));
  });

  test('PolyBLEP oscillators remain bounded with reverse frequency', () {
    final context = ProcessContext(sampleRate: 8, vectorSize: 4);
    final squareOutput = Float32List(4);
    final sawtoothOutput = Float32List(4);
    final triangleOutput = Float32List(4);

    SquareOscillatorProcessor(frequency: -2, usePolyBlep: true).process(
      context,
      [],
      [squareOutput],
    );
    SawtoothOscillatorProcessor(frequency: -2, usePolyBlep: true).process(
      context,
      [],
      [sawtoothOutput],
    );
    TriangleOscillatorProcessor(frequency: -2, usePolyBlep: true).process(
      context,
      [],
      [triangleOutput],
    );

    expect(squareOutput[0], closeTo(0.0, 1e-6));
    expect(sawtoothOutput[0], closeTo(0.0, 1e-6));
    expect(triangleOutput[0], closeTo(0.0, 1e-6));
    expect(triangleOutput[1], closeTo(-2.0 / 3.0, 1e-6));
    expect(
      squareOutput.every((sample) => sample >= -1.0 && sample <= 1.0),
      isTrue,
    );
    expect(
      sawtoothOutput.every((sample) => sample >= -1.0 && sample <= 1.0),
      isTrue,
    );
    expect(
      triangleOutput.every((sample) => sample >= -1.0 && sample <= 1.0),
      isTrue,
    );
  });
}
