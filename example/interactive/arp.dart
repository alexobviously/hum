import 'dart:async';
import 'dart:io' show stdin, stdout, exit;

import 'package:hum/hum.dart';

// You need ffmpeg installed with `ffplay` in path.

final allNotes = [
  'A3',
  'B3',
  'C4',
  'D4',
  'E4',
  'F4',
  'G4',
  'A4',
  'B4',
  'C5',
].map(Note.parse).toList();

void main() async {
  final sr = 44100, vs = 64;
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final host = await AudioHost.spawn(context: context);
  Synth synth = Synth(
    scale: [...allNotes],
    activeSteps: {for (int i = 0; i < 10; i++) i: true},
  );

  void updateGraph() => host.setGraph(root: synth.buildGraph());
  updateGraph();

  final output = await PipedAudioOutput.ffplay(
    numChannels: 1,
    vectorSize: vs,
    sampleRate: sr,
  );
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

    line('♫♫♫♫♫ ARPEGGIATOR');
    line('');
    line('(+/-) BPM\t\t${synth.bpm.toStringAsFixed(0)}');
    line('(←/→) Cutoff\t\t${synth.cutoff.toStringAsFixed(0)} Hz');
    line('(↑/↓) Reso\t\t${synth.reso.toStringAsFixed(2)}');
    line('(a/z) Sine\t\t${_levelToBar(synth.sineLevel)}');
    line('(s/x) Square\t\t${_levelToBar(synth.squareLevel)}');
    line('(d/c) Saw\t\t${_levelToBar(synth.sawLevel)}');

    line('');
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
      case [61]: // plus: tempo +5
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
    for (var i = 0; i < scale.length; i++)
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

    return Out(channels: [voiced.outlet]);
  }
}

String _levelToBar(double level) => [
  ...List.filled((level * 100) ~/ 5, '█'),
].join();

String _equalSpaceList(Iterable items, [int spacing = 4]) => [
  for (final x in items) '$x'.padRight(spacing),
].join();
