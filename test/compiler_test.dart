import 'package:dsp/src/compiler/graph_compiler.dart';
import 'package:dsp/src/core/audio_node.dart';
import 'package:dsp/src/core/audio_port.dart';
import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/process_context.dart';
import 'package:dsp/src/nodes/io/dac.dart';
import 'package:dsp/src/nodes/oscillators/sine_oscillator.dart';
import 'package:dsp/src/nodes/utils/gain.dart';
import 'package:dsp/src/nodes/utils/stereo_pan.dart';
import 'package:test/test.dart';

class _LoopNode implements AudioNode<AudioProcessor> {
  @override
  List<Inlet> inlets = [];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  @override
  AudioProcessor createProcessor() => throw UnimplementedError();

  @override
  Object get params => ();
}

void main() {
  test('discoverNodes finds all upstream reachable nodes', () {
    final sine = SineOscillator(frequency: .value(440));
    final gain = Gain.mono(gain: .value(0.5), input: sine.outlet);
    final pan = StereoPan(input: gain.outlets[0], pan: .value(0.0));
    final dac = Dac(channels: [pan.left, pan.right]);

    // An unattached node that should NOT be discovered
    final orphan = SineOscillator(frequency: .value(880));

    final discovered = discoverNodes([dac]);

    expect(discovered, containsAll([dac, pan, gain, sine]));
    expect(discovered, isNot(contains(orphan)));
    expect(discovered.length, equals(4));
  });

  test('topologicalSort sorts nodes in correct execution order', () {
    final sine = SineOscillator(frequency: .value(440));
    final gain = Gain.mono(gain: .value(0.5), input: sine.outlet);
    final pan = StereoPan(input: gain.outlets[0], pan: .value(0.0));
    final dac = Dac(channels: [pan.left, pan.right]);

    final discovered = discoverNodes([dac]);
    final sorted = topologicalSort(discovered);

    expect(sorted.length, equals(4));
    expect(sorted.indexOf(sine), lessThan(sorted.indexOf(gain)));
    expect(sorted.indexOf(gain), lessThan(sorted.indexOf(pan)));
    expect(sorted.indexOf(pan), lessThan(sorted.indexOf(dac)));
  });

  test('topologicalSort detects cycles and throws GraphCycleException', () {
    final a = _LoopNode();
    final b = _LoopNode();

    a.inlets = [Inlet(node: a, index: 0, source: b.outlets.first)];
    b.inlets = [Inlet(node: b, index: 0, source: a.outlets.first)];

    expect(() => topologicalSort({a, b}), throwsA(isA<GraphCycleException>()));
  });

  test('compilePipeline builds and executes complete rendering pipeline', () {
    final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
    final sine = SineOscillator(frequency: .value(440));
    final gain = Gain.mono(gain: .value(0.5), input: sine.outlet);
    final pan = StereoPan(input: gain.outlets[0], pan: .value(0.0));
    final dac = Dac(channels: [pan.left, pan.right]);

    final pipeline = compilePipeline(root: dac, context: context);

    expect(pipeline.steps.length, equals(4));
    expect(pipeline.numChannels, equals(2));

    // Render one block
    pipeline.process();

    final left = pipeline.outputs[0];
    final right = pipeline.outputs[1];

    expect(left.length, equals(64));
    expect(right.length, equals(64));

    // Center panning means left and right should be non-zero and equal
    expect(left[1], isNot(equals(0.0)));
    expect(left[1], closeTo(right[1], 1e-6));
  });

  test('AudioPipeline.update updates live processor without rebuild', () {
    final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
    final sine = SineOscillator(frequency: .value(440));
    final gain = Gain.mono(gain: .value(1.0), input: sine.outlet);
    final pipeline = compilePipeline(root: gain, context: context);

    final processor = pipeline.processorOf(gain);
    expect(processor.gain, equals(1.0));

    // Update gain node to 0.5
    final updatedGain = Gain.mono(gain: .value(0.5), input: sine.outlet);
    pipeline.update(gain, updatedGain);

    expect(processor.gain, equals(0.5));
  });
}
