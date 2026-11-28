import 'dart:async';
import 'dart:convert';
import 'dart:io' show exit, stderr, stdin, stdout;
import 'dart:math' as math;

import 'package:args/args.dart';
import 'package:hum/hum.dart';
import 'package:hum/io.dart';

import '../harness.dart' show AudioPlayerMode, resolvePlayer;

// TODO: clean this file up a bit, but tbh I might just make a TUI library and put some of this code there

class ParamPair({
  required final String name,
  required final String xLabel,
  required final String yLabel,
  required final String colour,
  required final String dimColour,
  final String Function(double x)? customFormatX,
  final String Function(double y)? customFormatY,
  final double driftRadiusX = 0.22,
  final double driftRadiusY = 0.22,
  var double x = 0.5,
  var double y = 0.5,
  var bool driftEnabled = false,
}) {
  late double anchorX = x;
  late double anchorY = y;
  double _vx = 0.0;
  double _vy = 0.0;

  String formatX() => customFormatX != null
      ? customFormatX!(x)
      : '${(x * 100).toStringAsFixed(0)}%';

  String formatY() => customFormatY != null
      ? customFormatY!(y)
      : '${(y * 100).toStringAsFixed(0)}%';

  void setPosition(double newX, double newY) {
    x = newX.clamp(0.0, 1.0);
    y = newY.clamp(0.0, 1.0);
    anchorX = x;
    anchorY = y;
    _vx = 0.0;
    _vy = 0.0;
  }

  void nudgeY(double delta) => setPosition(x, y + delta);

  void toggleDrift([bool? enabled]) {
    driftEnabled = enabled ?? !driftEnabled;
    if (driftEnabled) {
      anchorX = x;
      anchorY = y;
    }
    _vx = 0.0;
    _vy = 0.0;
  }

  void stepDrift(math.Random rng, double dt) {
    if (!driftEnabled) return;
    const damping = 1.6;
    const spring = 0.7;
    final sqrtDt = math.sqrt(dt);
    final impulseX = (rng.nextDouble() * 2.0 - 1.0) * 1.8 * driftRadiusX;
    final impulseY = (rng.nextDouble() * 2.0 - 1.0) * 1.8 * driftRadiusY;

    _vx += impulseX * sqrtDt - (spring * (x - anchorX) + damping * _vx) * dt;
    _vy += impulseY * sqrtDt - (spring * (y - anchorY) + damping * _vy) * dt;

    final minX = (anchorX - driftRadiusX).clamp(0.0, 1.0);
    final maxX = (anchorX + driftRadiusX).clamp(0.0, 1.0);
    final minY = (anchorY - driftRadiusY).clamp(0.0, 1.0);
    final maxY = (anchorY + driftRadiusY).clamp(0.0, 1.0);

    x = (x + _vx * dt).clamp(minX, maxX);
    y = (y + _vy * dt).clamp(minY, maxY);
  }
}

final availableChords = <Chord>[
  .maj9(.parse('D3')),
  .min7(.parse('A2')),
  .sus2(.parse('E3')),
  .maj7(.parse('F3')),
  .min7(.parse('D3')),
  .sus4(.parse('G2')),
  .major(.parse('Bb2')),
  .minor(.parse('C3')),
];

class Synth({
  required var Chord chord,
  var double brightness = 1.0,
  var double q = 50.0,
  var double spread = 0.85,
  var double filterCutoff = 950.0,
  var double swarmLevel = 0.45,
  var double sparkle = 0.45,
  var double motion = 0.45,
  var double delayTime = 0.38,
  var double space = 0.60,
  var double drive = 1.8,
  var double vinylCrackle = 0.30,
  var bool isMuted = false,
  var bool vinylEnabled = true,
  var bool swarmEnabled = true,
}) {
  Meter? meter;

  TerminalNode buildGraph() {
    // Excitation: steady pink noise bed + probabilistic resonant droplet bursts
    final pink = NoiseGenerator.pink();
    final white = NoiseGenerator.white();

    final sparkleClock = Clock(
      frequency: .value(1.8 + sparkle * 3.2),
      pulseWidth: const .value(0.2),
    );
    final sparkleGate = Chance(
      input: sparkleClock.trigger,
      probability: .value((sparkle * 0.78).clamp(0.0, 0.85)),
      seed: 7,
    );
    final sparkleEnv = Decay.ar(
      trigger: sparkleGate.a,
      attack: const .value(0.004),
      decay: const .value(0.055),
      curve: .exponential,
    );
    final burst = Mult.mono(
      input: white.outlet,
      value: .signal(sparkleEnv.outlet),
    ).outlet.mult(sparkle * 2.2);

    final excitation = pink.outlet.mult(0.85).outlet + burst.outlet;

    // Subtle tape wow / pitch drift LFO on resonators
    final driftDepth = motion * 0.009;
    final driftLfo = SineOscillator(
      frequency: const .value(0.13),
    ).mapRange(1.0 - driftDepth, 1.0 + driftDepth);

    final reso = ResonatorBank.chord(
      excitation,
      notes: chord.notes,
      frequencyMultiplier: .signal(driftLfo.outlet),
      q: .value(q),
      brightness: .value(brightness),
      spread: .value(spread),
    );

    final resoL = reso.left.mult(3.2);
    final resoR = reso.right.mult(3.2);

    // Rich sawtooth swarm + slow LFO-swept lowpass SVF
    final effectiveSwarm = (swarmEnabled && !isMuted) ? swarmLevel : 0.0;
    final swarm = Swarm.sawtooth(
      frequency: .value(chord.root.hz),
      voices: 7,
      detuneCents: 14.0 + motion * 18.0,
      stereoSpread: spread,
    );
    final minCut = (filterCutoff * (1.0 - 0.30 * motion - 0.10)).clamp(
      60.0,
      12000.0,
    );
    final maxCut = (filterCutoff * (1.0 + 0.45 * motion + 0.15)).clamp(
      80.0,
      14000.0,
    );
    final filterLfo = SineOscillator(
      frequency: const .value(0.09),
    ).mapRange(minCut, maxCut);

    final svfL = SvfFilter(
      input: swarm.left,
      cutoff: .signal(filterLfo.outlet),
      resonance: const .value(1.6),
    );
    final svfR = SvfFilter(
      input: swarm.right,
      cutoff: .signal(filterLfo.outlet),
      resonance: const .value(1.6),
    );

    final swarmGain = effectiveSwarm * 0.42;
    final swarmL = svfL.lowpass.mult(swarmGain);
    final swarmR = svfR.lowpass.mult(swarmGain);

    // Pre-gain into Saturator so Tape Drive adds audible harmonic warmth
    final combinedL = (resoL.outlet + swarmL.outlet).mult(2.4);
    final combinedR = (resoR.outlet + swarmR.outlet).mult(2.4);

    final sat = Saturator.stereo(
      combinedL.outlet,
      combinedR.outlet,
      drive: .value(drive),
      mode: .tanh,
      dcBlock: true,
    );

    final effectiveCrackle = (vinylEnabled && !isMuted) ? vinylCrackle : 0.0;
    final vinyl = VinylNoise.rpm33(
      crackle: .value(effectiveCrackle),
      hiss: const .value(0.04), // subtle background floor
      density: .value(5.0 + effectiveCrackle * 45.0),
      warp: const .value(0.12),
    );
    final vinylGain = (effectiveCrackle * 0.45).clamp(0.0, 0.35);
    final vinylL = vinyl.left.mult(vinylGain);
    final vinylR = vinyl.right.mult(vinylGain);

    final saturatedL = sat.left + vinylL.outlet;
    final saturatedR = sat.right + vinylR.outlet;

    final delay = Delay.stereo(
      leftInput: saturatedL,
      rightInput: saturatedR,
      time: .value(delayTime),
      feedback: .value((0.15 + space * 0.62).clamp(0.0, 0.80)),
      mix: const .value(0.42),
      damp: const .value(0.35),
      interpTime: 0.06,
    );

    final chorus = Chorus.stereo(
      leftInput: delay.left,
      rightInput: delay.right,
      rate: .value(0.35 + motion * 0.65),
      depth: .value(0.0015 + motion * 0.0035),
      baseDelay: const .value(0.015),
      mix: .value((0.15 + motion * 0.55).clamp(0.0, 0.75)),
    );

    final reverb = Freeverb.stereo(
      left: chorus.left,
      right: chorus.right,
      roomSize: .value((0.20 + space * 0.72).clamp(0.1, 0.95)),
      damp: const .value(0.35),
      mix: .value((0.18 + space * 0.62).clamp(0.0, 0.85)),
      interpTime: 0.03,
    );

    final comp = Compressor.stereo(
      reverb.left,
      reverb.right,
      threshold: const .value(-30.0),
      ratio: const .value(8.0),
      attack: const .value(0.015),
      release: const .value(0.200),
      knee: const .value(8.0),
      makeupGain: const .value(19.0),
    );

    final masterGain = isMuted ? 0.0 : 0.7;
    final masterL = comp.left.mult(masterGain, interpTime: 0.03);
    final masterR = comp.right.mult(masterGain, interpTime: 0.03);

    final m = meter = Meter.stereo(
      left: masterL.outlet,
      right: masterR.outlet,
    );

    return Out.stereo(left: m.left, right: m.right);
  }
}

final parser = ArgParser()
  ..addOption(
    'output',
    abbr: 'o',
    allowed: ['auto', 'sox', 'ffplay'],
    defaultsTo: 'auto',
    help: 'Audio output backend (auto prefers sox, falls back to ffplay)',
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
    if (stdout.terminalColumns < 80 || stdout.terminalLines < 26) {
      stderr.writeln(
        'Terminal is too small (${stdout.terminalColumns}x${stdout.terminalLines}). '
        'Please resize to at least 80x26.',
      );
      exit(1);
    }
  }

  const sr = 44100;
  const vs = 64;
  final playerMode = AudioPlayerMode.values.byName(results.option('output')!);
  final PipedAudioOutput output;
  try {
    output = await resolvePlayer(
      mode: playerMode,
      numChannels: 2,
      vectorSize: vs,
      sampleRate: sr,
    );
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  final player = output.executable == 'play' ? 'sox' : output.executable;

  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final host = await IsolateAudioHost.spawn(
    context: context,
    telemetryInterval: const Duration(milliseconds: 33),
  );

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
      name: 'Reso',
      xLabel: 'Brightness',
      yLabel: 'Resonance Q',
      colour: '\x1b[96m', // Bright Cyan
      dimColour: '\x1b[36m', // Cyan
      x: 0.46,
      y: 0.32,
      customFormatX: (x) => '${(0.15 + x * 1.85).toStringAsFixed(2)}x',
      customFormatY: (y) => (8.0 + y * 132.0).toStringAsFixed(0),
    ),
    ParamPair(
      name: 'Swarm',
      xLabel: 'Filter Cutoff',
      yLabel: 'Swarm Level',
      colour: '\x1b[92m', // Bright Green
      dimColour: '\x1b[32m', // Green
      x: 0.54,
      y: 0.45,
      customFormatX: (x) =>
          '${(140.0 * math.pow(34.0, x)).toStringAsFixed(0)} Hz',
      customFormatY: (y) => '${(y * 100).toStringAsFixed(0)}%',
    ),
    ParamPair(
      name: 'Motion',
      xLabel: 'Sparkles',
      yLabel: 'Drift/Chorus',
      colour: '\x1b[93m', // Bright Yellow
      dimColour: '\x1b[33m', // Yellow
      x: 0.45,
      y: 0.45,
    ),
    ParamPair(
      name: 'Space',
      xLabel: 'Delay Time',
      yLabel: 'Space & Verb',
      colour: '\x1b[94m', // Bright Blue
      dimColour: '\x1b[34m', // Blue
      driftRadiusX: 0.05,
      x: 0.41,
      y: 0.60,
      customFormatX: (x) =>
          '${((0.05 + x * 0.80) * 1000).toStringAsFixed(0)} ms',
      customFormatY: (y) => '${(y * 100).toStringAsFixed(0)}%',
    ),
    ParamPair(
      name: 'Grit',
      xLabel: 'Tape Drive',
      yLabel: 'Vinyl Crackle',
      colour: '\x1b[95m', // Bright Magenta
      dimColour: '\x1b[35m', // Magenta
      x: 0.13,
      y: 0.30,
      customFormatX: (x) => '${(1.0 + x * 6.0).toStringAsFixed(2)}x',
      customFormatY: (y) => '${(y * 100).toStringAsFixed(0)}%',
    ),
  ];

  int activePairIndex = 0;
  bool isDraggingPad = false;

  void syncSynthParams() {
    final p0 = pairs[0];
    synth.brightness = 0.15 + p0.x * 1.85;
    synth.q = 8.0 + p0.y * 132.0;

    final p1 = pairs[1];
    synth.filterCutoff = 140.0 * math.pow(34.0, p1.x);
    synth.swarmLevel = p1.y;

    final p2 = pairs[2];
    synth.sparkle = p2.x;
    synth.motion = p2.y;

    final p3 = pairs[3];
    synth.delayTime = 0.05 + p3.x * 0.80;
    synth.space = p3.y;

    final p4 = pairs[4];
    synth.drive = 1.0 + p4.x * 6.0;
    synth.vinylCrackle = p4.y;
  }

  syncSynthParams();

  void updateGraph() => host.setGraph(root: synth.buildGraph());
  updateGraph();

  final meterChannel = host.telemetryOf(synth.meter!);
  MeterReading? latestMeter;

  await host.startPlayback(output: output);

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
      final driftMark = p.driftEnabled ? '~' : '';
      final label = '[${i + 1}:${p.name.toUpperCase()}$driftMark]';
      if (isSel) {
        tabs.write('${p.colour}\x1b[1m$label\x1b[0m  ');
      } else if (p.driftEnabled) {
        tabs.write('${p.dimColour}$label\x1b[0m  ');
      } else {
        tabs.write('\x1b[90m$label\x1b[0m  ');
      }
    }
    tabs.write('\x1b[90m([1-5] / [←/→])\x1b[0m');
    line(tabs.toString());

    final activePair = pairs[activePairIndex];
    final chordName = '${synth.chord.root.name} ${synth.chord.pattern.name}';
    final chordNotesStr = synth.chord.notes.map((n) => n.name).join(' ');
    final driftBadge = activePair.driftEnabled ? ' \x1b[93m[DRIFT]\x1b[0m' : '';

    // Side panel lines (18 lines, corresponding to Rows 4 to 21)
    final side = [
      '${activePair.colour}\x1b[1mPAIR ${activePairIndex + 1}: ${activePair.name.toUpperCase()}\x1b[0m$driftBadge',
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
      '• Swarm+SVF   ${synth.swarmEnabled ? '\x1b[92m[${(synth.swarmLevel * 100).toStringAsFixed(0)}% / ${synth.filterCutoff.toStringAsFixed(0)}Hz]\x1b[0m' : '\x1b[90m[OFF]\x1b[0m'}',
      '• Motion      \x1b[93m[S: ${(synth.sparkle * 100).toStringAsFixed(0)}% / D: ${(synth.motion * 100).toStringAsFixed(0)}%]\x1b[0m',
      '• Delay/Verb  \x1b[94m[${(synth.delayTime * 1000).toStringAsFixed(0)}ms / ${(synth.space * 100).toStringAsFixed(0)}%]\x1b[0m',
      '• Tape Drive  \x1b[95m[${synth.drive.toStringAsFixed(1)}x]\x1b[0m',
      '• Vinyl       ${synth.vinylEnabled ? '\x1b[95m[${(synth.vinylCrackle * 100).toStringAsFixed(0)}%]\x1b[0m' : '\x1b[90m[OFF]\x1b[0m'}',
      '',
      '\x1b[1mKEYS:\x1b[0m [1-5] [d/D] [c] [v] [s]',
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

    // Rows 22-23: Stereo level meter below the XY pad
    final reading = latestMeter;
    line(_formatMeterLine('L', reading?.left));
    line(_formatMeterLine('R', reading?.right));

    // Row 24: Footer separator
    line('─' * 80);

    // Row 25: Tips
    line(
      'Drag pad | [1-5] Pair | [d/D] Drift | [c] Chord | [↑/↓] Oct | [Space] Mute',
    );

    stdout.write(buf.toString());
  }

  void handleInput(List<int> bytes) {
    if (completer.isCompleted) return;
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
        pairs[activePairIndex].nudgeY(0.03);
        syncSynthParams();
        updateGraph();
        render();
      } else if (button == 65) {
        // Scroll wheel down -> nudge Y
        pairs[activePairIndex].nudgeY(-0.03);
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
          pairs[activePairIndex].setPosition(normX, normY);
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
      if (!completer.isCompleted) completer.complete();
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

    // Strip arrow escape sequences before checking single-letter commands
    // (Left arrow is \x1b[D, which would otherwise match 'D').
    final keyChars = cleanText.replaceAll(RegExp(r'\x1b\[[ABCD]'), '');

    if (keyChars.contains('d')) {
      pairs[activePairIndex].toggleDrift();
    } else if (keyChars.contains('D')) {
      final anyDrifting = pairs.any((p) => p.driftEnabled);
      for (final p in pairs) {
        p.toggleDrift(!anyDrifting);
      }
    }

    if (keyChars.contains('c') || keyChars.contains('C')) {
      currentChordIndex = (currentChordIndex + 1) % availableChords.length;
      synth.chord = getActiveChord();
    }

    if (keyChars.contains('v') || keyChars.contains('V')) {
      synth.vinylEnabled = !synth.vinylEnabled;
    }

    if (keyChars.contains('s') || keyChars.contains('S')) {
      synth.swarmEnabled = !synth.swarmEnabled;
    }

    if (keyChars.contains(' ')) {
      synth.isMuted = !synth.isMuted;
    }

    updateGraph();
    render();
  }

  render();

  final driftRng = math.Random();
  const driftDt = 0.04;
  final driftTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
    bool changed = false;
    for (int i = 0; i < pairs.length; i++) {
      final p = pairs[i];
      if (p.driftEnabled && !(isDraggingPad && i == activePairIndex)) {
        p.stepDrift(driftRng, driftDt);
        changed = true;
      }
    }
    if (changed) {
      syncSynthParams();
      updateGraph();
      render();
    }
  });

  final meterSub = meterChannel?.stream.listen((reading) {
    latestMeter = reading;
    render();
  });
  final stdinSub = stdin.listen(handleInput);
  try {
    await completer.future;
  } finally {
    driftTimer.cancel();
    await meterSub?.cancel();
    stdin.lineMode = oldLineMode;
    stdin.echoMode = oldEchoMode;
    await stdinSub.cancel();
    await host.stopPlayback();
    await host.dispose();
    stdout.write(
      '\x1b]22;default\x1b\\\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?25h\x1b[?1049l',
    );
    stdout.writeln('Bye bye!');
    exit(0);
  }
}

String _formatMeterLine(String label, ChannelLevel? level) {
  const width = 32;
  const minDb = -48.0;

  final db = level?.peakDb ?? -120.0;
  final normalized = ((db - minDb) / -minDb).clamp(0.0, 1.0);
  final filled = (normalized * width).round();

  final bar = StringBuffer();
  for (int i = 0; i < width; i++) {
    if (i < filled) {
      final frac = i / width;
      final colour = frac > 0.88
          ? '\x1b[91m' // Red (near 0 dBFS)
          : frac > 0.70
          ? '\x1b[93m' // Yellow (-12..-3 dBFS)
          : '\x1b[92m'; // Green
      bar.write('$colour|\x1b[0m');
    } else {
      bar.write('\x1b[90m·\x1b[0m');
    }
  }

  final dbLabel = db <= -60.0
      ? '  -∞ dB'
      : '${db.toStringAsFixed(1).padLeft(5)} dB';
  final clipTag = (level?.clipped ?? false) ? ' \x1b[91mCLIP\x1b[0m' : '';
  return ' $label $bar $dbLabel$clipTag';
}
