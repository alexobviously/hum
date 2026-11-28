import 'package:hum/hum.dart';

import '../harness.dart';

// lol

/// Recreates the iconic DOOM E1M1 theme ("At Doom's Gate") using hum's
/// physical modeling, analog oscillators, multi-stage saturation, and drums.
///
/// Signal architecture across a 16-bar (256 16th-note) arrangement at 220 BPM:
/// - **Double-Tracked Rhythm Guitars (L/R):** Each side layers two [KarplusStrong]
///   strings (root + fifth) with per-step palm-mute damping (`0.86` chugs vs
///   `0.14` open power chords) and a detuned [SawtoothOscillator] power-chord
///   body, pushed through Tube Screamer pre-EQ, dual [Saturator] stages
///   (asymmetric tube + tanh crunch), and a resonant 4x12 cabinet [SvfFilter].
/// - **Screaming Harmony Lead (Bars 9–14):** [Swarm] sawtooth + [SquareOscillator]
///   with subtle LFO vibrato, tube saturation, wah-focused bandpass/lowpass
///   filtering, and dotted-eighth stereo [Delay].
/// - **Picked Metal Bass:** [SawtoothOscillator] + [TriangleOscillator] sub with
///   envelope-swept [SvfFilter] pick attack, [Saturator.tube] growl, and kick
///   sidechain ducking via [Compressor].
/// - **Thrash Drum Kit:** [Kick] + transient beater click, [Snare] with tight
///   [Freeverb] room snap, [HiHat.metallic] rides/chokes, and dual-layer crash
///   cymbals, glued through stereo saturation and bus compression.
void main(List<String> args) => runDemo(
  name: 'doom_theme_demo',
  tempo: const Tempo(220),
  bars: 16,
  description: 'DOOM E1M1 ("At Doom\'s Gate"): Karplus-Strong palm-muted thrash guitars, screaming harmony lead, picked bass, and double-kick drums.',
  args: args,
  builder: (context, tempo, _) {
    // Master 16th-note clock (16 steps/bar, 256 steps across the 16-bar loop).
    final clock = Clock(
      frequency: .value(1 / tempo.sixteenth),
      pulseWidth: const .value(0.5),
    );

    final score = _buildDoomScore();

    // -----------------------------------------------------------------------
    // 1. Sequencers (all sample-locked to master 16th-note clock)
    // -----------------------------------------------------------------------
    final guitarRootSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.guitarRootHz,
    );
    final guitarFifthSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.guitarFifthHz,
    );
    final guitarChugTrigSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.chugTrig,
    );
    final guitarOpenTrigSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.openTrig,
    );
    final guitarDampSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.guitarDamping,
    );
    final cabCutoffSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.cabCutoffHz,
    );

    final bassHzSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.bassHz,
    );
    final bassTrigSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.bassTrig,
    );

    final leadHzSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.leadHz,
    );
    final leadTrigSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.leadTrig,
    );

    final kickVelSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.kickVel,
    );
    final snareVelSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.snareVel,
    );
    final hatVelSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.hatVel,
    );
    final hatDecaySeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.hatDecay,
    );
    final crashVelSeq = StepSequencer.fromList(
      clock: clock.trigger,
      steps: score.crashVel,
    );

    // -----------------------------------------------------------------------
    // 2. Double-Tracked Distorted Thrash Rhythm Guitars (Left & Right)
    // -----------------------------------------------------------------------
    final chugTrig = clock.trigger * guitarChugTrigSeq.outlet;
    final openTrig = clock.trigger * guitarOpenTrigSeq.outlet;
    final anyGuitarTrig = Max.pair(chugTrig, openTrig).outlet;

    // Split envelopes: tight 72ms chug vs ringing 260ms power chord
    final chugEnv = Decay.pure(
      trigger: chugTrig,
      time: const .value(0.072),
      curve: .exponential,
    );
    final openEnv = Decay.pure(
      trigger: openTrig,
      time: const .value(0.260),
      curve: .exponential,
    );

    // Velocity scaling for open power chords vs palm mutes
    final chugAmp = chugEnv.outlet.mult(0.85).outlet;
    final openAmp = openEnv.outlet.mult(1.00).outlet;
    final dynamicEnv = Max.pair(chugAmp, openAmp).outlet;

    final guitarLeft = _buildGuitarChannel(
      gate: anyGuitarTrig,
      rootFreq: guitarRootSeq.cv,
      fifthFreq: guitarFifthSeq.cv,
      damping: guitarDampSeq.cv,
      cabCutoff: cabCutoffSeq.cv,
      env: dynamicEnv,
      detuneRatio: 0.9965, // -6 cents
      pickPosition: 0.12,
      bias: 0.28,
      pan: -0.78,
    );

    final guitarRight = _buildGuitarChannel(
      gate: anyGuitarTrig,
      rootFreq: guitarRootSeq.cv,
      fifthFreq: guitarFifthSeq.cv,
      damping: guitarDampSeq.cv,
      cabCutoff: cabCutoffSeq.cv,
      env: dynamicEnv,
      detuneRatio: 1.0038, // +6.5 cents
      pickPosition: 0.20,
      bias: -0.22,
      pan: 0.78,
    );

    final rhythmL = guitarLeft.left + guitarRight.left;
    final rhythmR = guitarLeft.right + guitarRight.right;

    // -----------------------------------------------------------------------
    // 3. Screaming 90s Harmony Lead Guitar (Bars 9-14)
    // -----------------------------------------------------------------------
    final leadTrig = clock.trigger * leadTrigSeq.outlet;
    final leadVel = Sah.mono(
      trigger: leadTrig,
      input: leadTrig,
      threshold: 0.0,
    );
    final leadEnv = Decay(
      trigger: leadTrig,
      attack: const .value(0.003),
      decay: const .value(0.30),
      curve: .exponential,
    );

    final vibratoLfo = SineOscillator(
      frequency: const .value(6.0),
    ).mapRange(0.992, 1.008);
    final leadFreqSlewed = Slew.mono(
      input: leadHzSeq.cv,
      time: const .value(0.008),
      initialValue: Note.parse('G4').hz,
    );
    final leadModFreq = leadFreqSlewed.outlet * vibratoLfo.outlet;

    final leadSwarm = Swarm.sawtooth(
      frequency: .signal(leadModFreq),
      voices: 3,
      detuneCents: 12.0,
      stereoSpread: 0.35,
    );
    final leadSquare = SquareOscillator(
      frequency: .signal(leadModFreq),
    );
    final leadOctave = SawtoothOscillator(
      frequency: .signal(leadModFreq.mult(2.0, interpTime: 0.0).outlet),
    );
    final leadRaw =
        leadSwarm.outlet.mult(0.75).outlet +
        leadSquare.outlet.mult(0.35).outlet +
        leadOctave.outlet.mult(0.28).outlet;

    final leadPreFilter = SvfFilter(
      input: leadRaw,
      cutoff: const .value(1850.0),
      resonance: const .value(2.1),
    );
    final leadShaped =
        leadPreFilter.lowpass.mult(0.60).outlet +
        leadPreFilter.bandpass.mult(0.65).outlet;

    final leadDrive = Saturator.tube(
      leadShaped,
      drive: const .value(6.0),
      bias: const .value(0.28),
    );
    final leadCab = SvfFilter(
      input: leadDrive.outlet,
      cutoff: const .value(4200.0),
      resonance: const .value(1.1),
    );
    final leadVoiced = Mult.mono(
      input: leadCab.lowpass,
      value: .signal(leadEnv.outlet * leadVel.outlet),
    );
    final leadDelay = Delay.stereo(
      leftInput: leadVoiced.outlet,
      rightInput: leadVoiced.outlet,
      time: .value(tempo.dottedEighth),
      feedback: const .value(0.28),
      mix: const .value(0.24),
      damp: const .value(0.30),
    );

    // -----------------------------------------------------------------------
    // 4. Picked Metal Bass Guitar (Doubling Riff Roots + Kick Ducking)
    // -----------------------------------------------------------------------
    final bassTrig = clock.trigger * bassTrigSeq.outlet;
    final bassEnv = Decay.pure(
      trigger: bassTrig,
      time: const .value(0.130),
      curve: .exponential,
    );
    final bassPickEnv = Decay.pure(
      trigger: bassTrig,
      time: const .value(0.036),
      curve: .exponential,
    );

    final bassSaw = SawtoothOscillator(frequency: .signal(bassHzSeq.cv));
    final bassSub = TriangleOscillator(frequency: .signal(bassHzSeq.cv));
    final bassOscMix =
        bassSaw.outlet.mult(0.72).outlet + bassSub.outlet.mult(0.38).outlet;

    final bassCutoff = Add.mono(
      input: bassPickEnv.outlet.mult(1800.0).outlet,
      value: const .value(260.0),
    );
    final bassFilter = SvfFilter(
      input: bassOscMix,
      cutoff: .signal(bassCutoff.outlet),
      resonance: const .value(1.45),
    );
    final bassDrive = Saturator.tube(
      bassFilter.lowpass,
      drive: const .value(3.0),
      bias: const .value(0.20),
      mix: const .value(0.85),
    );
    final bassVoiced = Mult.mono(
      input: bassDrive.outlet,
      value: .signal(bassEnv.outlet),
    );

    // -----------------------------------------------------------------------
    // 5. Thrash Drum Kit
    // -----------------------------------------------------------------------
    final kickTrig = clock.trigger * kickVelSeq.outlet;
    final kick = Kick(
      trigger: kickTrig,
      frequency: const .value(52.0),
      sweep: const .value(190.0),
      pitchDecay: const .value(0.022),
      decay: const .value(0.115),
      drive: const .value(2.4),
    );

    // Crisp thrash beater click so the double-kick cuts through guitars
    final beaterNoise = NoiseGenerator.white(seed: 7);
    final beaterFilter = SvfFilter(
      input: beaterNoise.outlet,
      cutoff: const .value(2900.0),
      resonance: const .value(1.4),
    );
    final beaterEnv = Decay.pure(
      trigger: kickTrig,
      time: const .value(0.008),
      curve: .exponential,
    );
    final beaterClick = Mult.mono(
      input: beaterFilter.bandpass,
      value: .signal(beaterEnv.outlet),
    );
    final kickFull =
        kick.outlet.mult(0.85).outlet + beaterClick.outlet.mult(0.45).outlet;

    final snareTrig = clock.trigger * snareVelSeq.outlet;
    final snare = Snare(
      trigger: snareTrig,
      frequency: const .value(205.0),
      sweep: const .value(125.0),
      pitchDecay: const .value(0.022),
      bodyDecay: const .value(0.095),
      noiseDecay: const .value(0.155),
      noiseCutoff: const .value(1450.0),
      bodyLevel: const .value(0.85),
      noiseLevel: const .value(1.00),
      seed: 101,
    );
    final snareRoom = Freeverb.mono(
      input: snare.outlet,
      roomSize: const .value(0.48),
      damp: const .value(0.40),
      mix: const .value(0.22),
    );

    final hat = HiHat.metallic(
      trigger: clock.trigger * hatVelSeq.outlet,
      decay: .signal(hatDecaySeq.cv),
      tune: 1.08,
    );
    final hatPan = StereoPan(
      input: hat.outlet.mult(0.36).outlet,
      pan: const .value(-0.28),
    );

    final crashTrig = clock.trigger * crashVelSeq.outlet;
    final crashMetal = HiHat.metallic(
      trigger: crashTrig,
      decay: const .value(0.65),
      tune: 0.86,
    );
    final crashWash = HiHat.noise(
      trigger: crashTrig,
      decay: const .value(0.55),
      cutoff: const .value(5000.0),
      resonance: const .value(0.8),
      seed: 202,
    );
    final crashPan = StereoPan(
      input:
          crashMetal.outlet.mult(0.45).outlet +
          crashWash.outlet.mult(0.30).outlet,
      pan: const .value(0.32),
    );

    // Sidechain-duck bass under kick for low-end clarity
    final bassDucked = Compressor.mono(
      bassVoiced.outlet,
      sidechain: kick.outlet,
      threshold: const .value(-16.0),
      ratio: const .value(4.0),
      attack: const .value(0.002),
      release: const .value(0.060),
      knee: const .value(3.0),
    );

    // Glue drum bus
    final drumBusL =
        kickFull.mult(0.62).outlet +
        snareRoom.left.mult(0.95).outlet +
        hatPan.left +
        crashPan.left;
    final drumBusR =
        kickFull.mult(0.62).outlet +
        snareRoom.right.mult(0.95).outlet +
        hatPan.right +
        crashPan.right;

    final drumSat = Saturator.stereo(
      drumBusL,
      drumBusR,
      drive: const .value(1.35),
      mix: const .value(0.65),
      mode: .tanh,
    );

    // -----------------------------------------------------------------------
    // 6. Stereo Mixdown & Master Bus
    // -----------------------------------------------------------------------
    // Subtle room ambience on guitars so they sit in the same room as the drums
    final guitarRoom = Freeverb.stereo(
      left: rhythmL.mult(0.95).outlet,
      right: rhythmR.mult(0.95).outlet,
      roomSize: const .value(0.34),
      damp: const .value(0.48),
      width: const .value(0.88),
      mix: const .value(0.10),
    );

    final mixL =
        drumSat.left +
        bassDucked.outlet.mult(0.36).outlet +
        guitarRoom.left +
        leadDelay.left.mult(0.75).outlet;
    final mixR =
        drumSat.right +
        bassDucked.outlet.mult(0.36).outlet +
        guitarRoom.right +
        leadDelay.right.mult(0.75).outlet;

    // Gentle master bus compression + peak limiting + tanh safety ceiling
    final masterGlue = Compressor.stereo(
      mixL,
      mixR,
      threshold: const .value(-11.0),
      ratio: const .value(2.4),
      attack: const .value(0.006),
      release: const .value(0.085),
      knee: const .value(4.0),
      makeupGain: const .value(1.2),
    );
    final masterLimited = Compressor.limiter(
      [masterGlue.left, masterGlue.right],
      threshold: const .value(-1.5),
      attack: const .value(0.0005),
      release: const .value(0.045),
    );
    final safetyClip = Saturator.stereo(
      masterLimited.outlets[0].mult(0.88).outlet,
      masterLimited.outlets[1].mult(0.88).outlet,
      drive: const .value(1.05),
      mode: .tanh,
    );

    return Mult.stereo(
      leftInput: safetyClip.left,
      rightInput: safetyClip.right,
      value: const .value(0.90),
    );
  },
);

/// Builds one side of the double-tracked thrash rhythm guitar rig:
/// Karplus-Strong physical strings (root + fifth) + detuned sawtooth body ->
/// Tube Screamer pre-EQ -> Tube preamp -> Tanh power amp -> 4x12 cab filter -> Pan.
StereoPan _buildGuitarChannel({
  required Outlet gate,
  required Outlet rootFreq,
  required Outlet fifthFreq,
  required Outlet damping,
  required Outlet cabCutoff,
  required Outlet env,
  required double detuneRatio,
  required double pickPosition,
  required double bias,
  required double pan,
}) {
  final detunedRoot = rootFreq.mult(detuneRatio, interpTime: 0.0).outlet;
  final detunedFifth = fifthFreq.mult(detuneRatio, interpTime: 0.0).outlet;

  // Physical string models with per-step palm-mute damping
  final ksRoot = KarplusStrong(
    gate: gate,
    frequency: .signal(detunedRoot),
    feedback: const .value(0.996),
    pickHardness: const .value(0.96),
    pickPosition: .value(pickPosition),
    damping: .signal(damping),
    interpTime: 0.002,
  );
  final ksFifth = KarplusStrong(
    gate: gate,
    frequency: .signal(detunedFifth),
    feedback: const .value(0.995),
    pickHardness: const .value(0.90),
    pickPosition: .value(pickPosition + 0.06),
    damping: .signal(damping),
    interpTime: 0.002,
  );

  // Harmonic sawtooth power-chord layer for thick 90s metal sustain
  final sawRoot = SawtoothOscillator(frequency: .signal(detunedRoot));
  final sawFifth = SawtoothOscillator(frequency: .signal(detunedFifth));
  final sawMixed =
      sawRoot.outlet.mult(0.65).outlet + sawFifth.outlet.mult(0.45).outlet;
  final sawVoiced = Mult.mono(input: sawMixed, value: .signal(env));

  final stringsRaw =
      ksRoot.outlet.mult(1.05).outlet +
      ksFifth.outlet.mult(0.75).outlet +
      sawVoiced.outlet.mult(0.65).outlet;

  // Tube Screamer pre-EQ: tighten lows (<135 Hz) & push aggressive 1.1 kHz mids
  final tightHp = SvfFilter(
    input: stringsRaw,
    cutoff: const .value(135.0),
    resonance: const .value(0.8),
  );
  final midPush = SvfFilter(
    input: tightHp.highpass,
    cutoff: const .value(1100.0),
    resonance: const .value(1.7),
  );
  final preAmpInput =
      tightHp.highpass.mult(0.90).outlet + midPush.bandpass.mult(0.75).outlet;

  // Cascaded high-gain amp stages (asymmetric triode -> power-amp tanh)
  final preamp = Saturator.tube(
    preAmpInput,
    drive: const .value(5.6),
    bias: .value(bias),
    dcBlock: true,
  );
  final powerAmp = Saturator.mono(
    preamp.outlet,
    drive: const .value(3.4),
    bias: const .value(0.06),
    mode: .tanh,
    dcBlock: true,
  );

  // 4x12 Cabinet simulation: dynamic lowpass + 1.4 kHz speaker cone bite
  final cabFilter = SvfFilter(
    input: powerAmp.outlet,
    cutoff: .signal(cabCutoff),
    resonance: const .value(1.25),
  );
  final cabBite = SvfFilter(
    input: cabFilter.lowpass,
    cutoff: const .value(1350.0),
    resonance: const .value(1.3),
  );
  final cabOut =
      cabFilter.lowpass.mult(0.85).outlet + cabBite.bandpass.mult(0.35).outlet;

  // Smooth gate release post-amp (only trims tail silence without crushing attack)
  final gatedGuitar = Mult.mono(
    input: cabOut,
    value: .signal(env),
  );

  return StereoPan(input: gatedGuitar.outlet, pan: .value(pan));
}

typedef _DoomScore = ({
  List<double> guitarRootHz,
  List<double> guitarFifthHz,
  List<double> chugTrig,
  List<double> openTrig,
  List<double> guitarDamping,
  List<double> cabCutoffHz,
  List<double> bassHz,
  List<double> bassTrig,
  List<double> leadHz,
  List<double> leadTrig,
  List<double> kickVel,
  List<double> snareVel,
  List<double> hatVel,
  List<double> hatDecay,
  List<double> crashVel,
});

/// Compiles the 16-bar (256-step at 16th-note resolution) E1M1 arrangement.
_DoomScore _buildDoomScore() {
  final guitarRootHz = <double>[];
  final guitarFifthHz = <double>[];
  final chugTrig = <double>[];
  final openTrig = <double>[];
  final guitarDamping = <double>[];
  final cabCutoffHz = <double>[];
  final bassHz = <double>[];
  final bassTrig = <double>[];
  final leadHz = <double>[];
  final leadTrig = <double>[];
  final kickVel = <double>[];
  final snareVel = <double>[];
  final hatVel = <double>[];
  final hatDecay = <double>[];
  final crashVel = <double>[];

  // Helper: parse a 2-bar (16 eighth-note slots -> 32 sixteenth steps) riff.
  // Token suffix:
  //   'm' = palm-muted chug (1 sixteenth tight hit)
  //   'o' = open power chord (2 sixteenths ring)
  //   's' = sustained power chord (2 sixteenths ring, high accent)
  void addGuitarRiff(List<String> eighthSlots, {String? leadPattern}) {
    final leadTokens = leadPattern?.trim().split(RegExp(r'\s+')) ?? const [];
    double lastLeadHz = Note.parse('G4').hz;
    if (leadHz.isNotEmpty) lastLeadHz = leadHz.last;

    for (int i = 0; i < eighthSlots.length; i++) {
      final token = eighthSlots[i];
      final isMuted = token.endsWith('m');
      final isStrong = token.endsWith('s');
      final noteName = (isMuted || isStrong || token.endsWith('o'))
          ? token.substring(0, token.length - 1)
          : token;

      final rootNote = Note.parse(noteName);
      final fifthNote = rootNote.fifth;
      final bassNote = rootNote.downOctave();

      // Step A (on the 8th-note attack)
      guitarRootHz.add(rootNote.hz);
      guitarFifthHz.add(fifthNote.hz);
      chugTrig.add(isMuted ? 1.0 : 0.0);
      openTrig.add(isMuted ? 0.0 : (isStrong ? 1.0 : 0.92));
      guitarDamping.add(isMuted ? 0.86 : 0.14);
      cabCutoffHz.add(isMuted ? 1950.0 : 3900.0);

      bassHz.add(bassNote.hz);
      bassTrig.add(1.0);

      // Step B (second 16th of the 8th-note slot)
      guitarRootHz.add(rootNote.hz);
      guitarFifthHz.add(fifthNote.hz);
      chugTrig.add(0.0);
      openTrig.add(0.0);
      guitarDamping.add(isMuted ? 0.88 : 0.14);
      cabCutoffHz.add(isMuted ? 1750.0 : 3700.0);

      bassHz.add(bassNote.hz);
      bassTrig.add(0.0);

      // Optional harmony lead on open accents
      final leadTok = i < leadTokens.length ? leadTokens[i] : '.';
      if (leadTok != '.') {
        lastLeadHz = Note.parse(leadTok).hz;
        leadHz.addAll([lastLeadHz, lastLeadHz]);
        leadTrig.addAll([1.0, 0.0]);
      } else {
        leadHz.addAll([lastLeadHz, lastLeadHz]);
        leadTrig.addAll([0.0, 0.0]);
      }
    }
  }

  // Classic 2-bar E1M1 riffs (16 eighth-note slots each)
  const riffE = [
    'E2m',
    'E2m',
    'E3o',
    'E2m',
    'E2m',
    'D3o',
    'E2m',
    'E2m',
    'C3o',
    'E2m',
    'E2m',
    'Bb2s',
    'E2m',
    'E2m',
    'B2o',
    'C3o',
  ];
  const riffA = [
    'A2m',
    'A2m',
    'A3o',
    'A2m',
    'A2m',
    'G3o',
    'A2m',
    'A2m',
    'F3o',
    'A2m',
    'A2m',
    'Eb3s',
    'A2m',
    'A2m',
    'E3o',
    'F3o',
  ];
  const riffB = [
    'B2m',
    'B2m',
    'B3o',
    'B2m',
    'B2m',
    'A3o',
    'B2m',
    'B2m',
    'G3o',
    'B2m',
    'B2m',
    'F#3s',
    'E3o',
    'D3o',
    'C3o',
    'B2s',
  ];

  // Harmonized upper lead patterns (diatonic major/minor 3rds over riffs)
  const leadOverE = '. . G4 . . F#4 . . E4 . . D4 . . D#4 E4';
  const leadOverA = '. . C5 . . B4  . . A4 . . G4 . . G#4 A4';
  const leadOverB = '. . D5 . . C#5 . . B4 . . A4 . . G4  F#4';

  // Build 16-bar melodic/harmonic sequence:
  // Bars 1-2: Intro E
  addGuitarRiff(riffE);
  // Bars 3-4: Main E
  addGuitarRiff(riffE);
  // Bars 5-6: A transposition
  addGuitarRiff(riffA);
  // Bars 7-8: Return to E
  addGuitarRiff(riffE);
  // Bars 9-10: E + Harmony Lead
  addGuitarRiff(riffE, leadPattern: leadOverE);
  // Bars 11-12: A + Harmony Lead
  addGuitarRiff(riffA, leadPattern: leadOverA);
  // Bars 13-14: E + Harmony Lead
  addGuitarRiff(riffE, leadPattern: leadOverE);
  // Bars 15-16: B Turnaround + Harmony Lead
  addGuitarRiff(riffB, leadPattern: leadOverB);

  // Build 16-bar (256-step) Thrash Drum Arrangement
  void addDrumBar({
    required List<double> k,
    required List<double> s,
    required List<double> h,
    required List<double> hd,
    List<double>? c,
  }) {
    kickVel.addAll(k);
    snareVel.addAll(s);
    hatVel.addAll(h);
    hatDecay.addAll(hd);
    crashVel.addAll(
      c ?? const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    );
  }

  // Standard driving thrash groove (16 steps = 1 bar)
  const kMain = [
    1.0,
    0.0,
    0.8,
    0.0,
    0.0,
    0.0,
    0.85,
    0.0,
    1.0,
    0.0,
    0.85,
    0.0,
    0.0,
    0.0,
    0.7,
    0.0,
  ];
  const kPush = [
    1.0,
    0.0,
    0.8,
    0.0,
    0.0,
    0.0,
    0.90,
    0.0,
    1.0,
    0.0,
    0.85,
    0.0,
    0.0,
    0.7,
    0.8,
    0.9,
  ];
  const kDouble = [
    1.0,
    0.85,
    1.0,
    0.85,
    0.0,
    0.0,
    0.9,
    0.8,
    1.0,
    0.85,
    1.0,
    0.85,
    0.0,
    0.0,
    0.9,
    0.85,
  ];

  const sMain = [
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
  ];
  const sFill = [
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.9,
    0.7,
    0.85,
    1.0,
  ];
  const sIntroBuild = [
    0.0,
    0.0,
    0.0,
    0.0,
    0.7,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.85,
    0.7,
    0.9,
    1.0,
  ];

  const hDrive = [
    0.85,
    0.0,
    0.65,
    0.0,
    0.80,
    0.0,
    0.65,
    0.0,
    0.85,
    0.0,
    0.65,
    0.0,
    0.80,
    0.0,
    0.75,
    0.0,
  ];
  const hdDrive = [
    0.045,
    0.045,
    0.045,
    0.045,
    0.045,
    0.045,
    0.095,
    0.045,
    0.045,
    0.045,
    0.045,
    0.045,
    0.045,
    0.045,
    0.14,
    0.045,
  ];
  const hIntro = [
    0.70,
    0.0,
    0.45,
    0.0,
    0.65,
    0.0,
    0.45,
    0.0,
    0.70,
    0.0,
    0.45,
    0.0,
    0.65,
    0.0,
    0.55,
    0.0,
  ];

  const cHit = <double>[1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  const cDouble = <double>[1, 0, 0, 0, 0, 0, 0, 0, 0.85, 0, 0, 0, 0, 0, 0, 0];

  // Bar 1-2: Intro groove + snare pickup
  addDrumBar(k: kMain, s: sMain, h: hIntro, hd: hdDrive, c: cHit);
  addDrumBar(k: kPush, s: sIntroBuild, h: hIntro, hd: hdDrive);
  // Bar 3-4: Full E riff
  addDrumBar(k: kMain, s: sMain, h: hDrive, hd: hdDrive, c: cHit);
  addDrumBar(k: kPush, s: sMain, h: hDrive, hd: hdDrive);
  // Bar 5-6: A riff
  addDrumBar(k: kMain, s: sMain, h: hDrive, hd: hdDrive, c: cHit);
  addDrumBar(k: kPush, s: sMain, h: hDrive, hd: hdDrive);
  // Bar 7-8: E riff + fill into harmony section
  addDrumBar(k: kMain, s: sMain, h: hDrive, hd: hdDrive, c: cHit);
  addDrumBar(k: kPush, s: sFill, h: hDrive, hd: hdDrive);
  // Bar 9-10: E + Lead
  addDrumBar(k: kMain, s: sMain, h: hDrive, hd: hdDrive, c: cHit);
  addDrumBar(k: kPush, s: sMain, h: hDrive, hd: hdDrive);
  // Bar 11-12: A + Lead
  addDrumBar(k: kMain, s: sMain, h: hDrive, hd: hdDrive, c: cHit);
  addDrumBar(k: kPush, s: sMain, h: hDrive, hd: hdDrive);
  // Bar 13-14: E + Lead
  addDrumBar(k: kMain, s: sMain, h: hDrive, hd: hdDrive, c: cHit);
  addDrumBar(k: kPush, s: sFill, h: hDrive, hd: hdDrive);
  // Bar 15-16: B turnaround double-kick + big snare roll turnaround
  addDrumBar(k: kDouble, s: sMain, h: hDrive, hd: hdDrive, c: cDouble);
  addDrumBar(
    k: kDouble,
    s: sFill,
    h: hDrive,
    hd: hdDrive,
    c: const <double>[0.9, 0, 0, 0, 0, 0, 0, 0, 0.85, 0, 0, 0, 0.8, 0, 0, 0],
  );

  return (
    guitarRootHz: guitarRootHz,
    guitarFifthHz: guitarFifthHz,
    chugTrig: chugTrig,
    openTrig: openTrig,
    guitarDamping: guitarDamping,
    cabCutoffHz: cabCutoffHz,
    bassHz: bassHz,
    bassTrig: bassTrig,
    leadHz: leadHz,
    leadTrig: leadTrig,
    kickVel: kickVel,
    snareVel: snareVel,
    hatVel: hatVel,
    hatDecay: hatDecay,
    crashVel: crashVel,
  );
}
