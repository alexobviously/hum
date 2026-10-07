import 'dart:typed_data';

import 'package:dsp/dsp.dart';
import 'package:test/test.dart';

void main() {
  test('dsp library exports core symbols and builds simple graph', () {
    final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
    final sine = SineOscillator(frequency: .value(440));
    final gain = Gain.mono(gain: .value(0.8), input: sine.outlet);
    final pipeline = compilePipeline(root: gain, context: context);

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

  test('PolyBLEP oscillators remain bounded with reverse frequency', () {
    final context = ProcessContext(sampleRate: 8, vectorSize: 4);
    final squareOutput = Float32List(4);
    final sawtoothOutput = Float32List(4);

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

    expect(squareOutput[0], closeTo(0.0, 1e-6));
    expect(sawtoothOutput[0], closeTo(0.0, 1e-6));
    expect(
      squareOutput.every((sample) => sample >= -1.0 && sample <= 1.0),
      isTrue,
    );
    expect(
      sawtoothOutput.every((sample) => sample >= -1.0 && sample <= 1.0),
      isTrue,
    );
  });
}
