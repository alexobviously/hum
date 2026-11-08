import 'dart:async';
import 'dart:io' show exit, stdin, stdout;

import 'package:args/args.dart';
import 'package:hum/hum.dart';

// You need ffmpeg installed with `ffplay` or SoX installed with `play` in path.

final availableScales = <Scale>[
  .minor(.parse('A3')),
  .dorian(.parse('A3')),
  .phrygian(.parse('A3')),
  .minorPentatonic(.parse('A3')),
  .blues(.parse('A3')),
  .harmonicMinor(.parse('A3')),
  .major(.parse('C4')),
  .majorPentatonic(.parse('C4')),
];

final parser = ArgParser()
  ..addOption(
    'output',
    abbr: 'o',
    allowed: ['ffplay', 'sox'],
    defaultsTo: 'ffplay',
    help: 'Audio output backend (ffplay or sox/play)',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Show help message',
  );

void main(List<String> args) async {
  final results = parser.parse(args);

  if (results['help'] == true) {
    stdout.writeln('Interactive Arpeggiator');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final player = results.option('output')!;

  final sr = 44100, vs = 64;
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final host = await AudioHost.spawn(context: context);
  int currentScaleIndex = 0;
  Synth synth = Synth(
    scale: availableScales[currentScaleIndex].take(10),
    activeSteps: {for (int i = 0; i < 10; i++) i: true},
  );

  void updateGraph() => host.setGraph(root: synth.buildGraph());
  updateGraph();

  final output = switch (player) {
    'sox' => await PipedAudioOutput.sox(
      numChannels: 2,
      vectorSize: vs,
      sampleRate: sr,
    ),
    _ => await PipedAudioOutput.ffplay(
      numChannels: 2,
      vectorSize: vs,
      sampleRate: sr,
    ),
  };
  await host.startPlayback(output);

  final oldLineMode = stdin.lineMode;
  final oldEchoMode = stdin.echoMode;
  stdin.lineMode = false;
  stdin.echoMode = false;
  stdout.write('\x1b[?1049h\x1b[?25l');

  final completer = Completer<void>();

  void render() {
    final buf = StringBuffer();
    buf.write('\x1b[H'); // Move cursor to top-left (1, 1)

    void line(String text) =>
        buf.writeln('$text\x1b[K'); // Clear line to the right

    line('♫♫♫♫♫ ARPEGGIATOR [$player]');
    line('');
    final scaleName =
        '${availableScales[currentScaleIndex].root.name} ${availableScales[currentScaleIndex].pattern.name}';
    line('${'(m)   Scale'.padRight(24)}$scaleName');
    line('${'(+/-) BPM'.padRight(24)}${synth.bpm.toStringAsFixed(0)}');
    line('${'(←/→) Cutoff'.padRight(24)}${synth.cutoff.toStringAsFixed(0)} Hz');
    line('${'(↑/↓) Reso'.padRight(24)}${synth.reso.toStringAsFixed(2)}');
    line(
      '${'(,/.) Delay Feedback'.padRight(24)}${synth.delayFeedback.toStringAsFixed(2)}',
    );
    line(
      '${'(</>) Delay Mix'.padRight(24)}${synth.delayMix.toStringAsFixed(2)}',
    );
    line('${'(a/z) Sine'.padRight(24)}${_levelToBar(synth.sineLevel)}');
    line('${'(s/x) Square'.padRight(24)}${_levelToBar(synth.squareLevel)}');
    line('${'(d/c) Saw'.padRight(24)}${_levelToBar(synth.sawLevel)}');

    line('');
    line('Press number keys to toggle steps');
    line('Notes: [ ${_equalSpaceList([1, 2, 3, 4, 5, 6, 7, 8, 9, 0])} ]');
    line(
      'State: [ ${_equalSpaceList([
        for (int i = 0; i < synth.scale.length; i++) synth.isStepActive(i) ? synth.scale[i].name.padRight(2) : '..',
      ])} ]',
    );
    line('');
    line('Press [q] or [Ctrl+C] to quit');

    stdout.write(buf.toString());
  }

  void handleInput(List<int> codeUnits) {
    switch (codeUnits) {
      case [113]: // q: exit
        completer.complete();
      case [61]: // plus: tempo +5 (actually equals)
        synth.bpm = (synth.bpm + 5).clamp(10, 300);
      case [45]: // minus: tempo -5
        synth.bpm = (synth.bpm - 5).clamp(10, 300);
      case [27, 91, 65]: // ↑: reso + 0.1
        synth.reso = (synth.reso + 0.1).clamp(0, 5);
      case [27, 91, 66]: // ↓: reso - 0.1
        synth.reso = (synth.reso - 0.1).clamp(0, 5);
      case [27, 91, 67]: // →: cutoff + 100
        synth.cutoff = (synth.cutoff + 100).clamp(100, 20000);
      case [27, 91, 68]: // ←: cutoff - 100
        synth.cutoff = (synth.cutoff - 100).clamp(100, 20000);
      case [final n] when n >= 49 && n <= 57: // 1-9: toggle first 9 notes
        synth.toggleStep(n - 49);
      case [48]: // 0: toggle last note (thank mr ascii)
        synth.toggleStep(9);
      case [97]: // a: sine level +0.05
        synth.sineLevel = (synth.sineLevel + 0.05).clamp(0, 1);
      case [122]: // z: sine level -0.05
        synth.sineLevel = (synth.sineLevel - 0.05).clamp(0, 1);
      case [115]: // s: square level +0.05
        synth.squareLevel = (synth.squareLevel + 0.05).clamp(0, 1);
      case [120]: // x: square level -0.05
        synth.squareLevel = (synth.squareLevel - 0.05).clamp(0, 1);
      case [100]: // d: saw level +0.05
        synth.sawLevel = (synth.sawLevel + 0.05).clamp(0, 1);
      case [99]: // c: saw level -0.05
        synth.sawLevel = (synth.sawLevel - 0.05).clamp(0, 1);
      case [44]: // ,: delay feedback -0.05
        synth.delayFeedback = (synth.delayFeedback - 0.05).clamp(0, 1);
      case [46]: // .: delay feedback +0.05
        synth.delayFeedback = (synth.delayFeedback + 0.05).clamp(0, 1);
      case [60]: // <: delay mix: -0.05
        synth.delayMix = (synth.delayMix - 0.05).clamp(0, 1);
      case [62]: // >: delay mix: +0.05
        synth.delayMix = (synth.delayMix + 0.05).clamp(0, 1);
      case [109]: // m: cycle scale mode
        currentScaleIndex = (currentScaleIndex + 1) % availableScales.length;
        synth.scale = availableScales[currentScaleIndex].take(10);
    }
    render();
    updateGraph();
  }

  render();
  try {
    stdin.listen(handleInput);
    await completer.future;
  } finally {
    await host.stopPlayback();
    await host.dispose();
    stdin.lineMode = oldLineMode;
    stdin.echoMode = oldEchoMode;
    stdout.write('\x1b[?25h\nBye bye!\n');
    exit(0);
  }
}

class Synth({
  required var List<Note> scale,
  required var Map<int, bool> activeSteps,
  var double bpm = 120,
  var double cutoff = 2000,
  var double reso = 2.5,
  var double sineLevel = 0.5,
  var double squareLevel = 0.2,
  var double sawLevel = 0.3,
  var double delayFeedback = 0.4,
  var double delayMix = 0.1,
}) {
  bool isStepActive(int index) => activeSteps[index] ?? false;

  void toggleStep(int index) {
    final currentlyActive = activeSteps[index] ?? false;
    if (currentlyActive) {
      final activeCount = activeSteps.values.where((v) => v).length;
      if (activeCount <= 1) return; // Prevent disabling all notes
      activeSteps[index] = false;
    } else {
      activeSteps[index] = true;
    }
  }

  List<Note> get activeNotes => [
    for (int i = 0; i < scale.length; i++)
      if (activeSteps[i] ?? false) scale[i],
  ];

  TerminalNode buildGraph() {
    final notes = activeNotes;
    final tempo = Tempo(bpm);
    final clock = Clock(
      frequency: .value(1 / tempo.sixteenth),
      pulseWidth: const .value(0.5),
    );

    final seq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: [
        for (final n in notes) n.hz,
      ],
    );

    final pitch = seq; //.slew(0.015, notes.first.hz);

    final sine = SineOscillator(
      frequency: .signal(pitch.outlet),
    ).outlet.mult(sineLevel);

    final square = SquareOscillator(
      frequency: .signal(pitch.outlet),
    ).outlet.mult(squareLevel);

    final saw = SawtoothOscillator(
      frequency: .signal(pitch.outlet),
    ).outlet.mult(sawLevel);

    final summed = sine.outlet + square.outlet + saw.outlet;
    final clamped = summed.clip(1);

    final env = Adsr(
      gate: clock.gate,
      attack: const .value(0.005),
      decay: .value(tempo.sixteenth * 0.9),
      sustain: const .value(0.1),
      release: const .value(0.02),
      curve: .exponential,
    );

    final filter = SvfFilter(
      input: clamped,
      cutoff: .value(cutoff),
      resonance: .value(reso),
    );

    final voiced = Mult.mono(
      value: .signal(env.outlet),
      input: filter.lowpass,
    );

    final delay = Delay.mono(
      input: voiced.outlet,
      time: .value(tempo.dottedSixteenth),
      feedback: .value(delayFeedback),
      mix: .value(delayMix),
    );

    final reverb = Freeverb.mono(input: delay.outlet);

    return Out(channels: reverb.outlets);
  }
}

String _levelToBar(double level) => [
  ...List.filled((level * 100) ~/ 5, '█'),
].join();

String _equalSpaceList(Iterable items, [int spacing = 4]) => [
  for (final x in items) '$x'.padRight(spacing),
].join();
