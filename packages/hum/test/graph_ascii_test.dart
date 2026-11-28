import 'package:hum/hum.dart';
import 'package:test/test.dart';

void main() {
  group('formatGraphAscii', () {
    test('renders empty GraphSnapshot gracefully', () {
      expect(
        GraphSnapshot.empty.toAscii(title: 'empty'),
        equals('empty\n(empty graph)'),
      );
    });

    test('renders linear chain with source, processor, and terminal', () {
      final osc = SineOscillator(frequency: const .value(440));
      final mult = Mult.mono(value: const .value(0.5), input: osc.outlet);
      final out = Out.mono(mult.outlet);

      final ascii = formatGraphAscii(root: out, title: 'linear');

      expect(ascii, contains('linear (3 nodes, 2 edges,'));
      expect(ascii, contains('○  #0 SineOscillator (frequency: 440.0)'));
      expect(ascii, contains('●  #1 Mult (interpTime: 0.02, value: 0.5)'));
      expect(ascii, contains('◆  #2 Out'));
    });

    test('renders fan-out and fan-in with multi-outlet stereo nodes', () {
      final osc = SineOscillator(frequency: const .value(220));
      final chorus = Chorus.toStereo(input: osc.outlet, rate: const .value(0.5));
      final reverb = Freeverb.stereo(left: chorus.left, right: chorus.right);
      final out = Out.stereo(left: reverb.left, right: reverb.right);

      final ascii = formatGraphAscii(root: out);

      expect(ascii, contains('├─╮'));
      expect(ascii, contains('Freeverb'));
      expect(ascii, contains('← #1.0, #1.1'));
      expect(ascii, contains('◆─╯'));
    });

    test('renders non-terminal graph with output termination markers', () {
      final osc = SineOscillator(frequency: const .value(330));
      final filter = SvfFilter(input: osc.outlet, cutoff: const .value(800));

      final ascii = formatGraphAscii(root: filter);

      expect(ascii, contains('▼'));
      expect(ascii, contains('graph output'));
    });

    test('supports slot display, compactOrder: false, and hidden params', () {
      final osc = SineOscillator(frequency: const .value(440));
      final gain = Mult.mono(value: const .value(0.25), input: osc.outlet);
      final out = Out.mono(gain.outlet);

      final snapshot = compileGraph(root: out).snapshot!;
      final ascii = snapshot.toAscii(
        options: const GraphAsciiOptions(
          compactOrder: false,
          showParams: false,
          showSlots: true,
          showInputRefs: false,
        ),
      );

      expect(ascii, contains('[slot '));
      expect(ascii, isNot(contains('440.0')));
      expect(ascii, isNot(contains('←')));
    });

    test('returns compilation diagnostics when graph validation fails', () {
      final invalid = Sum(inputs: const []);
      final ascii = formatGraphAscii(root: invalid);

      expect(ascii, contains('Graph compilation failed:'));
      expect(ascii, contains('Sum'));
    });
  });
}
