import 'dart:async';
import 'dart:convert';
import 'dart:io' show exit, stderr, stdin, stdout;

import 'package:args/args.dart';
import 'package:hum/hum.dart';
import 'package:hum/io.dart';

// TODO: clean this file up a bit, but tbh I might just make a TUI library and put some of this code there

class ParamPair({
  required final String name,
  required final String xLabel,
  required final String yLabel,
  required final String colour,
  required final String dimColour,
  final String Function(double x)? customFormatX,
  final String Function(double y)? customFormatY,
  var double x = 0.5,
  var double y = 0.5,
}) {
  String formatX() => customFormatX != null
      ? customFormatX!(x)
      : '${(x * 100).toStringAsFixed(0)}%';

  String formatY() => customFormatY != null
      ? customFormatY!(y)
      : '${(y * 100).toStringAsFixed(0)}%';
}

final availableChords = <Chord>[
  .maj9(Note.parse('D3')),
  .min7(Note.parse('A2')),
  .sus2(Note.parse('E3')),
  .maj7(Note.parse('F3')),
  .min7(Note.parse('D3')),
  .sus4(Note.parse('G2')),
  .major(Note.parse('Bb2')),
  .minor(Note.parse('C3')),
];

class Synth({
  required var Chord chord,
  var double brightness = 1.0,
  var double q = 45.0,
  var double spread = 0.85,
  var double delayTime = 0.38,
  var double delayFeedback = 0.40,
  var double delayMix = 0.4,
  var double reverbSize = 0.65,
  var double reverbDamp = 0.40,
  var double drive = 1.2,
  var double vinylCrackle = 0.35,
  var double swarmLevel = 0.20,
  var double swarmDetune = 12.0,
  var bool isMuted = false,
  var bool vinylEnabled = true,
  var bool swarmEnabled = true,
}) {
  TerminalNode buildGraph() {
    final noise = NoiseGenerator.pink();
    final reso = ResonatorBank.chord(
      noise.outlet,
      notes: chord.notes,
      frequencyMultiplier: const .value(1.0),
      q: .value(q),
      brightness: .value(brightness),
      spread: .value(spread),
    );

    final resoL = reso.left.mult(0.65);
    final resoR = reso.right.mult(0.65);

    final effectiveSwarm = (swarmEnabled && !isMuted) ? swarmLevel : 0.0;
    final swarm = Swarm(
      frequency: .value(chord.root.hz),
      waveform: SwarmWaveform.sine,
      voices: 5,
      detuneCents: swarmDetune,
      stereoSpread: spread,
    );
    final swarmL = swarm.left.mult(effectiveSwarm);
    final swarmR = swarm.right.mult(effectiveSwarm);

    final combinedL = resoL.outlet + swarmL.outlet;
    final combinedR = resoR.outlet + swarmR.outlet;

    final sat = Saturator.stereo(
      combinedL,
      combinedR,
      drive: .value(drive),
      mode: SaturationMode.tanh,
    );

    final effectiveCrackle = (vinylEnabled && !isMuted) ? vinylCrackle : 0.0;
    final vinyl = VinylNoise.rpm33(
      crackle: .value(effectiveCrackle),
      hiss: const .value(0.04), // subtle background floor
      density: .value(5.0 + effectiveCrackle * 45.0),
      warp: const .value(0.12),
    );
    final vinylGain = (effectiveCrackle * 0.5).clamp(0.0, 0.4);
    final vinylL = vinyl.left.mult(vinylGain);
    final vinylR = vinyl.right.mult(vinylGain);

    final saturatedL = sat.left + vinylL.outlet;
    final saturatedR = sat.right + vinylR.outlet;

    final delay = Delay.stereo(
      leftInput: saturatedL,
      rightInput: saturatedR,
      time: .value(delayTime),
      feedback: .value(delayFeedback),
      mix: .value(delayMix),
      interpTime: 0.06,
    );

    final reverb = Freeverb.stereo(
      left: delay.left,
      right: delay.right,
      roomSize: .value(reverbSize),
      damp: .value(reverbDamp),
      mix: .value((reverbSize * 0.75).clamp(0.0, 1.0)),
      interpTime: 0.03,
    );

    final masterGain = isMuted ? 0.0 : 0.35;
    final masterL = reverb.left.mult(masterGain, interpTime: 0.03);
    final masterR = reverb.right.mult(masterGain, interpTime: 0.03);

    return Out.stereo(left: masterL.outlet, right: masterR.outlet);
  }
}

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
    stdout.writeln('Interactive Texture / Ambient Drone Workbench');
    stdout.writeln(parser.usage);
    exit(0);
  }

  if (stdout.hasTerminal) {
    if (stdout.terminalColumns < 80 || stdout.terminalLines < 24) {
      stderr.writeln(
        'Terminal is too small (${stdout.terminalColumns}x${stdout.terminalLines}). '
        'Please resize to at least 80x24.',
      );
      exit(1);
    }
  }

  final player = results.option('output')!;
  const sr = 44100;
  const vs = 64;
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final host = await IsolateAudioHost.spawn(context: context);

  int currentChordIndex = 0;
  int octaveOffset = 0;

  Chord getActiveChord() {
    var c = availableChords[currentChordIndex];
    if (octaveOffset > 0) {
      for (int i = 0; i < octaveOffset; i++) {
        if (c.root.octave < 5) {
          c = Chord(c.root.upOctave(), c.pattern);
        }
      }
    } else if (octaveOffset < 0) {
      for (int i = 0; i < -octaveOffset; i++) {
        if (c.root.octave > 1) {
          c = Chord(c.root.downOctave(), c.pattern);
        }
      }
    }
    return c;
  }

  final synth = Synth(chord: getActiveChord());

  final pairs = [
    ParamPair(
      name: 'Timbre',
      xLabel: 'Brightness',
      yLabel: 'Resonance Q',
      colour: '\x1b[96m', // Bright Cyan
      dimColour: '\x1b[36m', // Cyan
      x: 0.47,
      y: 0.33,
      customFormatX: (x) => '${(0.1 + x * 1.9).toStringAsFixed(2)}x',
      customFormatY: (y) => (8.0 + y * 112.0).toStringAsFixed(0),
    ),
    ParamPair(
      name: 'Delay',
      xLabel: 'Delay Time',
      yLabel: 'Feedback',
      colour: '\x1b[94m', // Bright Blue
      dimColour: '\x1b[34m', // Blue
      x: 0.41,
      y: 0.47,
      customFormatX: (x) =>
          '${((0.05 + x * 0.80) * 1000).toStringAsFixed(0)} ms',
      customFormatY: (y) => '${(y * 85).toStringAsFixed(0)}%',
    ),
    ParamPair(
      name: 'Verb',
      xLabel: 'Room Size',
      yLabel: 'Dampening',
      colour: '\x1b[95m', // Bright Magenta
      dimColour: '\x1b[35m', // Magenta
      x: 0.65,
      y: 0.40,
      customFormatX: (x) => '${((0.10 + x * 0.85) * 100).toStringAsFixed(0)}%',
      customFormatY: (y) => '${(y * 100).toStringAsFixed(0)}%',
    ),
    ParamPair(
      name: 'Grit',
      xLabel: 'Drive',
      yLabel: 'Vinyl Crackle',
      colour: '\x1b[93m', // Bright Yellow
      dimColour: '\x1b[33m', // Yellow
      x: 0.10,
      y: 0.35,
      customFormatX: (x) => '${(1.0 + x * 3.5).toStringAsFixed(2)}x',
      customFormatY: (y) => '${(y * 100).toStringAsFixed(0)}%',
    ),
    ParamPair(
      name: 'Swarm',
      xLabel: 'Swarm Level',
      yLabel: 'Detune Spread',
      colour: '\x1b[92m', // Bright Green
      dimColour: '\x1b[32m', // Green
      x: 0.44,
      y: 0.21,
      customFormatX: (x) => '${(x * 45).toStringAsFixed(0)}%',
      customFormatY: (y) => '${(3.0 + y * 42.0).toStringAsFixed(1)} cents',
    ),
  ];

  int activePairIndex = 0;
  bool isDraggingPad = false;

  void syncSynthParams() {
    final p0 = pairs[0];
    synth.brightness = 0.1 + p0.x * 1.9;
    synth.q = 8.0 + p0.y * 112.0;

    final p1 = pairs[1];
    synth.delayTime = 0.05 + p1.x * 0.80;
    synth.delayFeedback = p1.y * 0.85;

    final p2 = pairs[2];
    synth.reverbSize = 0.10 + p2.x * 0.85;
    synth.reverbDamp = p2.y;

    final p3 = pairs[3];
    synth.drive = 1.0 + p3.x * 3.5;
    synth.vinylCrackle = p3.y;

    final p4 = pairs[4];
    synth.swarmLevel = p4.x * 0.45;
    synth.swarmDetune = 3.0 + p4.y * 42.0;
  }

  syncSynthParams();

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

  // Alternate buffer + Hide cursor + Mouse button (1000) + Mouse drag (1002)
  // + SGR 1006 + OSC 22 Pointer Shape
  stdout.write(
    '\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b]22;crosshair\x1b\\',
  );

  final completer = Completer<void>();
  final mouseRegex = RegExp(r'\x1b\[<(\d+);(\d+);(\d+)([Mm])');

  void render() {
    final buf = StringBuffer();
    buf.write('\x1b[H'); // Home (1, 1)

    void line(String text) => buf.writeln('$text\x1b[K');

    // Row 1: Header
    line(
      '♫ AMBIENT TEXTURE / DRONE WORKBENCH [$player]                [q] Quit',
    );
    // Row 2: Divider
    line('─' * 80);

    // Row 3: Tabs
    final tabs = StringBuffer(' ');
    for (int i = 0; i < pairs.length; i++) {
      final p = pairs[i];
      final isSel = i == activePairIndex;
      final label = '[${i + 1}:${p.name.toUpperCase()}]';
      if (isSel) {
        tabs.write('${p.colour}\x1b[1m$label\x1b[0m  ');
      } else {
        tabs.write('\x1b[90m$label\x1b[0m  ');
      }
    }
    tabs.write('\x1b[90m(Keys [1-5] / [←/→])\x1b[0m');
    line(tabs.toString());

    final activePair = pairs[activePairIndex];
    final chordName = '${synth.chord.root.name} ${synth.chord.pattern.name}';
    final chordNotesStr = synth.chord.notes.map((n) => n.name).join(' ');

    // Side panel lines (18 lines, corresponding to Rows 4 to 21)
    final side = [
      '${activePair.colour}\x1b[1mPAIR ${activePairIndex + 1}: ${activePair.name.toUpperCase()}\x1b[0m',
      '──────────────────────────────────',
      '[X] ${activePair.xLabel.padRight(14)} ${activePair.formatX()}',
      '[Y] ${activePair.yLabel.padRight(14)} ${activePair.formatY()}',
      '',
      '\x1b[1mACTIVE CHORD\x1b[0m',
      '[c] $chordName ($chordNotesStr)',
      '[↑/↓] Root Octave: ${synth.chord.root.octave}',
      '',
      '\x1b[1mCHAIN STATUS\x1b[0m',
      '• Resonators  \x1b[96m[B: ${synth.brightness.toStringAsFixed(2)} / Q: ${synth.q.toStringAsFixed(0)}]\x1b[0m',
      '• Delay Line  \x1b[94m[${(synth.delayTime * 1000).toStringAsFixed(0)}ms / ${(synth.delayFeedback * 100).toStringAsFixed(0)}%]\x1b[0m',
      '• Freeverb    \x1b[95m[${(synth.reverbSize * 100).toStringAsFixed(0)}% / ${(synth.reverbDamp * 100).toStringAsFixed(0)}% dmp]\x1b[0m',
      '• Tape Drive  \x1b[93m[${synth.drive.toStringAsFixed(1)}x]\x1b[0m',
      '• Vinyl       ${synth.vinylEnabled ? '\x1b[93m[${(synth.vinylCrackle * 100).toStringAsFixed(0)}%]\x1b[0m' : '\x1b[90m[OFF]\x1b[0m'}',
      '• Swarm       ${synth.swarmEnabled ? '\x1b[92m[${(synth.swarmLevel * 100).toStringAsFixed(0)}%]\x1b[0m' : '\x1b[90m[OFF]\x1b[0m'}',
      '',
      '\x1b[1mKEYS:\x1b[0m [1-5]  [c] [v] [s] [Space]',
    ];

    // Row 4: Top border + side[0]
    line(' ┌${'─' * 40}┐  ${side[0]}');

    // Rows 5..20: Pad inner (16 rows) + side[1..16]
    for (int r = 0; r < 16; r++) {
      final padLine = StringBuffer(' │');
      final activeC = (activePair.x * 39).round().clamp(0, 39);
      final activeR = ((1.0 - activePair.y) * 15).round().clamp(0, 15);

      for (int c = 0; c < 40; c++) {
        int? inactIdx;
        for (int p = 0; p < pairs.length; p++) {
          if (p != activePairIndex) {
            final pairC = (pairs[p].x * 39).round().clamp(0, 39);
            final pairR = ((1.0 - pairs[p].y) * 15).round().clamp(0, 15);
            if (c == pairC && r == pairR) {
              inactIdx = p;
              break;
            }
          }
        }

        if (c == activeC && r == activeR) {
          padLine.write('${activePair.colour}\x1b[1m┼\x1b[0m');
        } else if (inactIdx != null) {
          final ip = pairs[inactIdx];
          padLine.write('${ip.colour}\x1b[1m${inactIdx + 1}\x1b[0m');
        } else if (r == activeR) {
          padLine.write('${activePair.dimColour}─\x1b[0m');
        } else if (c == activeC) {
          padLine.write('${activePair.dimColour}│\x1b[0m');
        } else if (r == 7 && c == 19) {
          padLine.write('\x1b[90m·\x1b[0m');
        } else {
          padLine.write(' ');
        }
      }

      padLine.write('│  ${side[r + 1]}');
      line(padLine.toString());
    }

    // Row 21: Bottom border + side[17]
    line(' └${'─' * 40}┘  ${side[17]}');

    // Row 22: Footer separator
    line('─' * 80);

    // Row 23: Tips
    line(
      'Mouse: Drag inside pad | [1-5]/[←/→] Pairs | [c] Chord | [↑/↓] Oct | [Space] Mute',
    );

    stdout.write(buf.toString());
  }

  void handleInput(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);

    // 1. Mouse Input Handling (SGR 1006)
    final mouseMatches = mouseRegex.allMatches(text);
    if (mouseMatches.isNotEmpty) {
      final m = mouseMatches.last;
      final button = int.parse(m.group(1)!);
      final col = int.parse(m.group(2)!);
      final row = int.parse(m.group(3)!);
      final isDown = m.group(4) == 'M';

      if (button == 64) {
        // Scroll wheel up -> nudge Y
        pairs[activePairIndex].y = (pairs[activePairIndex].y + 0.03).clamp(
          0.0,
          1.0,
        );
        syncSynthParams();
        updateGraph();
        render();
      } else if (button == 65) {
        // Scroll wheel down -> nudge Y
        pairs[activePairIndex].y = (pairs[activePairIndex].y - 0.03).clamp(
          0.0,
          1.0,
        );
        syncSynthParams();
        updateGraph();
        render();
      } else if (isDown) {
        // Left click down or drag: only initiate if inside pad boundaries
        if (row >= 5 && row <= 20 && col >= 3 && col <= 42) {
          isDraggingPad = true;
        }

        if (isDraggingPad) {
          final normX = ((col - 3) / 39.0).clamp(0.0, 1.0);
          final normY = (1.0 - ((row - 5) / 15.0)).clamp(0.0, 1.0);
          pairs[activePairIndex].x = normX;
          pairs[activePairIndex].y = normY;
          syncSynthParams();
          updateGraph();
          render();
        }
      } else {
        // Button release
        isDraggingPad = false;
      }
    }

    // 2. Keyboard Input Handling
    final cleanText = text.replaceAll(mouseRegex, '');
    if (cleanText.isEmpty) return;

    if (cleanText.contains('q') ||
        cleanText.contains('Q') ||
        cleanText.contains('\x03')) {
      completer.complete();
      return;
    }

    if (cleanText.contains('1')) {
      activePairIndex = 0;
    } else if (cleanText.contains('2')) {
      activePairIndex = 1;
    } else if (cleanText.contains('3')) {
      activePairIndex = 2;
    } else if (cleanText.contains('4')) {
      activePairIndex = 3;
    } else if (cleanText.contains('5')) {
      activePairIndex = 4;
    }

    if (cleanText.contains('\x1b[D')) {
      // Left arrow
      activePairIndex = (activePairIndex - 1 + pairs.length) % pairs.length;
    } else if (cleanText.contains('\x1b[C')) {
      // Right arrow
      activePairIndex = (activePairIndex + 1) % pairs.length;
    }

    if (cleanText.contains('\x1b[A')) {
      // Up arrow: octave up
      if (synth.chord.root.octave < 5) {
        octaveOffset++;
        synth.chord = getActiveChord();
      }
    } else if (cleanText.contains('\x1b[B')) {
      // Down arrow: octave down
      if (synth.chord.root.octave > 1) {
        octaveOffset--;
        synth.chord = getActiveChord();
      }
    }

    if (cleanText.contains('c') || cleanText.contains('C')) {
      currentChordIndex = (currentChordIndex + 1) % availableChords.length;
      synth.chord = getActiveChord();
    }

    if (cleanText.contains('v') || cleanText.contains('V')) {
      synth.vinylEnabled = !synth.vinylEnabled;
    }

    if (cleanText.contains('s') || cleanText.contains('S')) {
      synth.swarmEnabled = !synth.swarmEnabled;
    }

    if (cleanText.contains(' ')) {
      synth.isMuted = !synth.isMuted;
    }

    updateGraph();
    render();
  }

  render();

  try {
    stdin.listen(handleInput);
    await completer.future;
  } finally {
    await host.stopPlayback();
    await host.dispose();
    stdout.write(
      '\x1b]22;default\x1b\\\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?25h\x1b[?1049l',
    );
    stdin.lineMode = oldLineMode;
    stdin.echoMode = oldEchoMode;
    stdout.writeln('Bye bye!');
    exit(0);
  }
}
