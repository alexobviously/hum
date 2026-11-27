import 'package:hum/hum.dart';

import '../harness.dart';

// This was a clanker's attempt, mostly out of curiousity for what it could do
// with what we had. It's useful because it gives me some idea of what's
// really missing for composition right now.

/// Demonstrates a 168 BPM 90s jungle / Amen-style breakbeat + Reese & 808
/// sub-bass line built with the [Kick], [Snare], [HiHat] (both [HiHat.noise]
/// and [HiHat.metallic]), and [Clap] composite drum voices.
///
/// Features:
/// - **4-bar Amen break phrasing** (64 16th-note steps):
///   - Bars 1–2: Classic syncopated Amen pattern (kick on `1`, `1&`, `3&`, `3a`;
///     snare on `2`, `4`, plus displaced syncopations on `2a`/`3e` and rapid
///     ghost-note shuffles).
///   - Bar 3: Delayed-snare chop (snare pushed from beat 2 to `2&`, extended
///     double-kick pressure, and a machine-gun 16th snare roll across beat 4).
///   - Bar 4: Pitch-shifted high snare fill (modulating `Snare.frequency` per
///     step via a [StepSequencer], like a sampler pitching an Amen slice up)
///     and open-hat splash turnaround.
/// - **Per-step hi-hat choke / open-close modulation**: a single [HiHat.noise]
///   whose `decay` parameter is driven by a [StepSequencer] so open hats ring
///   out and closed steps choke them tight.
/// - **Exposed-clap accents** on syncopated offbeats (where the snare isn't
///   firing) plus layered backbeats so the 4-burst handclap snap is clearly
///   audible.
/// - **Jungle LFO Wobble Bass**:
///   - Gliding pitch sequence in F minor (`F1`, `Ab1`, `Bb1`, `Db1`, `Eb1`, plus
///     an `F2` octave jump on the bar-3 drop) with portamento via [Slew].
///   - Tempo-synced LFO whose rate is sequenced per beat (`quarter` → `eighth` →
///     `tripletEighth` → `sixteenth`) so the resonant lowpass filter does the
///     classic "wob-wob-wob" speed-up across the phrase.
void main(List<String> args) => runDemo(
  name: 'percussion_demo',
  tempo: const Tempo(168),
  bars: 4,
  description: '168 BPM jungle breakbeat with Reese + 808 sub bassline, chopped snare rolls, and dynamic hat chokes.',
  args: args,
  builder: (context, tempo, _) {
    // Master 16th-note clock at 168 BPM
    final clock = Clock(
      frequency: .value(1 / tempo.sixteenth),
      pulseWidth: const .value(0.1),
    );

    // 64-step (4-bar) patterns.
    // Grid per bar:  1    e    &    a  |  2    e    &    a  |  3    e    &    a  |  4    e    &    a
    final kickVel = clock.trigger.stepSequencer(
      steps: [
        // Bar 1: Classic Amen (1, 1&, 3&, 3a)
        1.00, 0.00, 0.85, 0.00, 0.00, 0.00, 0.00, 0.00,
        0.00, 0.00, 0.95, 0.75, 0.00, 0.00, 0.00, 0.00,
        // Bar 2: Amen variation with turnaround pickup on 4a
        1.00, 0.00, 0.85, 0.00, 0.00, 0.00, 0.00, 0.00,
        0.00, 0.60, 0.95, 0.00, 0.00, 0.00, 0.00, 0.55,
        // Bar 3: Displaced jungle chop (triple kick bounce before delayed snare)
        1.00, 0.00, 0.80, 0.00, 0.85, 0.00, 0.00, 0.00,
        0.00, 0.70, 0.95, 0.00, 0.00, 0.00, 0.00, 0.00,
        // Bar 4: Half-time drop on beat 1, then syncopated stabs into the fill
        1.00, 0.00, 0.00, 0.70, 0.00, 0.00, 0.85, 0.00,
        0.00, 0.00, 0.90, 0.00, 0.00, 0.00, 0.00, 0.00,
      ],
    );

    final snareVel = clock.trigger.stepSequencer(
      steps: [
        // Bar 1: Backbeat on 2 & 4 + signature Amen ghost shuffle (2a, 3e, 4a)
        0.00, 0.00, 0.00, 0.00, 1.00, 0.00, 0.00, 0.38,
        0.00, 0.42, 0.00, 0.00, 1.00, 0.00, 0.00, 0.35,
        // Bar 2: Displaced second snare (3a + 4e) like the Amen bar-2 chop
        0.00, 0.00, 0.00, 0.00, 1.00, 0.00, 0.00, 0.38,
        0.00, 0.40, 0.00, 0.00, 0.00, 0.30, 0.95, 0.42,
        // Bar 3: Snare pushed to 2& + rapid 16th rush across beat 4
        0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 1.00, 0.35,
        0.00, 0.40, 0.00, 0.35, 0.80, 0.55, 0.75, 0.90,
        // Bar 4: Jungle pitched-up snare break fill across beats 3 & 4
        0.00, 0.32, 0.00, 0.00, 1.00, 0.00, 0.00, 0.40,
        0.85, 0.45, 0.00, 0.65, 0.95, 0.70, 0.85, 1.00,
      ],
    );

    // Modulate snare body pitch per step: sits at 225 Hz for normal hits/ghosts,
    // jumps up during the bar-3 roll and bar-4 pitched break chop.
    final snarePitch = clock.trigger.stepSequencer(
      steps: [
        // Bars 1–2: steady 225 Hz (slightly higher on ghost notes for snap)
        225, 225, 225, 225, 220, 225, 225, 250,
        225, 255, 225, 225, 220, 225, 225, 250,
        225, 225, 225, 225, 220, 225, 225, 250,
        225, 255, 225, 225, 225, 250, 225, 260,
        // Bar 3: rising pitch across the beat-4 16th roll
        225, 225, 225, 225, 225, 225, 220, 250,
        225, 250, 225, 255, 240, 265, 290, 320,
        // Bar 4: classic pitched-up sampler fill
        225, 250, 225, 225, 220, 225, 225, 255,
        280, 280, 225, 310, 340, 340, 380, 420,
      ],
    );

    // Fast shuffling 16th-note ride/hat velocity
    final hatVel = clock.trigger.stepSequencer(
      steps: [
        0.80,
        0.40,
        0.65,
        0.45,
        0.75,
        0.40,
        0.70,
        0.50,
        0.80,
        0.45,
        0.70,
        0.45,
        0.75,
        0.40,
        0.65,
        0.55,
      ],
    );

    // Per-step hat decay (choke): short 28ms on tight 16ths, opens to 140ms on
    // key offbeats so the next 16th step naturally chokes the tail.
    final hatDecay = clock.trigger.stepSequencer(
      steps: [
        0.028,
        0.025,
        0.095,
        0.025,
        0.028,
        0.025,
        0.130,
        0.025,
        0.028,
        0.025,
        0.095,
        0.025,
        0.028,
        0.025,
        0.145,
        0.028,
      ],
    );

    // Metallic 808 cymbal/ride ping on syncopated jungle accents
    final metalHatVel = clock.trigger.stepSequencer(
      steps: [
        0.65,
        0.00,
        0.50,
        0.00,
        0.00,
        0.00,
        0.60,
        0.00,
        0.00,
        0.00,
        0.70,
        0.00,
        0.00,
        0.00,
        0.55,
        0.40,
      ],
    );

    // Clap: placed both on solo syncopated offbeats (1a, 3& in bar 4, etc. so
    // you can hear the 4-burst handclap in isolation) and layered on key snares.
    final clapVel = clock.trigger.stepSequencer(
      steps: [
        // Bar 1: solo syncopated clap on 2& + layered on beat 4
        0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.85, 0.00,
        0.00, 0.00, 0.00, 0.00, 0.95, 0.00, 0.00, 0.00,
        // Bar 2: solo clap on 1a and 3e + turnaround accent
        0.00, 0.00, 0.00, 0.80, 0.00, 0.00, 0.00, 0.00,
        0.00, 0.85, 0.00, 0.00, 0.90, 0.00, 0.00, 0.00,
        // Bar 3: solo clap on beat 2 (where the snare was chopped out!)
        0.00, 0.00, 0.00, 0.00, 0.95, 0.00, 0.00, 0.00,
        0.80, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00,
        // Bar 4: double-clap call before the snare fill
        0.00, 0.00, 0.85, 0.00, 0.00, 0.85, 0.00, 0.00,
        0.00, 0.00, 0.00, 0.00, 1.00, 0.00, 0.00, 0.00,
      ],
    );

    // Drum Voices
    final kick = Kick(
      trigger: clock.trigger * kickVel.outlet,
      frequency: const .value(46.0),
      sweep: const .value(150.0),
      pitchDecay: const .value(0.030),
      decay: const .value(0.20),
      drive: const .value(2.1),
    );

    final snare = Snare(
      trigger: clock.trigger * snareVel.outlet,
      frequency: .signal(snarePitch.outlet),
      sweep: const .value(110.0),
      pitchDecay: const .value(0.020),
      bodyDecay: const .value(0.070),
      noiseDecay: const .value(0.115),
      noiseCutoff: const .value(1950.0),
      bodyLevel: const .value(0.70),
      noiseLevel: const .value(0.90),
      seed: 11,
    );

    final shuffHat = HiHat.noise(
      trigger: clock.trigger * hatVel.outlet,
      decay: .signal(hatDecay.outlet),
      cutoff: const .value(7600.0),
      resonance: const .value(1.2),
      seed: 23,
    );

    final metalRide = HiHat.metallic(
      trigger: clock.trigger * metalHatVel.outlet,
      decay: const .value(0.16),
      tune: 1.15,
    );

    final clap = Clap(
      trigger: clock.trigger * clapVel.outlet,
      spread: 0.012,
      burstDecay: const .value(0.009),
      tailDecay: const .value(0.15),
      tailLevel: const .value(0.45),
      cutoff: const .value(1300.0),
      resonance: const .value(2.0),
      seed: 37,
    );

    // -------------------------------------------------------------------------
    // Jungle LFO "Wob-Wob" Wobble Bassline (F minor)
    // -------------------------------------------------------------------------
    // Pitch sequence stepped on every 16th; held notes repeat their target pitch
    // while `Slew` bends smoothly across note transitions.
    final bassPitchSeq = StepSequencer.sequence(
      clock: clock.trigger,
      sequence:
          // Bar 1: heavy root F1 (~43.65 Hz) → Ab1 jump on 2& → Eb1 drop on 3&
          'F1 F1 F1 F1 F1 F1 Ab1 Ab1 Ab1 Ab1 Eb1 Eb1 Eb1 Eb1 Eb1 Eb1 '
          // Bar 2: dark Db1 weight → C1 turnaround walk back up to F1
          'Db1 Db1 Db1 Db1 Db1 Db1 Db1 Db1 Eb1 Eb1 C1 C1 C1 C1 Eb1 Eb1 '
          // Bar 3: octave-jump F2 (~87.3 Hz) divebomb on beat 1 → Bb1 → Ab1
          'F2 F2 F1 F1 F1 F1 F1 F1 Bb1 Bb1 Ab1 Ab1 Ab1 Ab1 F1 F1 '
          // Bar 4: syncopated Db1 → Eb1 → F1/C1 turnaround under the snare roll
          'Db1 Db1 Db1 Db1 Eb1 Eb1 Eb1 Eb1 F1 F1 Ab1 Ab1 Bb1 Bb1 C1 C1',
    );

    final bassFreq = Slew.mono(
      input: bassPitchSeq.outlet,
      rise: const .value(0.0008),
      fall: const .value(0.0014),
      initialValue: Note.parse('F1').hz,
    );

    // Tempo-synced wobble LFO rates in Hz:
    //   w1  = quarter-note wobble (2.8 Hz: deep slow "woooob")
    //   w2  = eighth-note wobble (5.6 Hz: classic "wob-wob")
    //   w3t = triplet-eighth wobble (8.4 Hz: rolling jungle triplet "wob-wob-wob")
    //   w4  = sixteenth-note wobble (11.2 Hz: fast stutter tearout)
    final w1 = tempo.frequencyOf(.quarter);
    final w2 = tempo.frequencyOf(.eighth);
    final w3t = tempo.frequencyOf(.eighth, triplet: true);
    final w4 = tempo.frequencyOf(.sixteenth);

    // Step the LFO rate across the 4-bar phrase so the wobble speeds up and
    // slows down rhythmically against the Amen break.
    final wobbleRateSeq = clock.trigger.stepSequencer(
      steps: [
        // Bar 1: 8th "wob-wob" on F1 → triplet-8th on Ab1 → slow quarter on Eb1
        w2, w2, w2, w2, w2, w2, w3t, w3t,
        w3t, w3t, w1, w1, w1, w1, w2, w2,
        // Bar 2: slow heavy Db1 → triplet-8th → fast 16th wobble turnaround
        w1, w1, w1, w1, w2, w2, w2, w2,
        w3t, w3t, w3t, w3t, w4, w4, w4, w4,
        // Bar 3: fast 16th tearout on the F2 drop → 8th groove → triplet-8th
        w4, w4, w2, w2, w2, w2, w2, w2,
        w3t, w3t, w3t, w3t, w2, w2, w2, w2,
        // Bar 4: triplet-8th → 8th → 16th machine-gun wobble under the snare fill
        w3t, w3t, w3t, w3t, w2, w2, w2, w2,
        w3t, w3t, w3t, w3t, w4, w4, w4, w4,
      ],
    );

    // LFO sweeps the resonant lowpass cutoff between a deep 95 Hz floor and a
    // biting 1850 Hz vowel peak ("wob-wob").
    final wobbleLfo = SineOscillator(
      frequency: .signal(wobbleRateSeq.outlet),
    ).mapRange(95.0, 1850.0);

    // Harmonic-rich oscillator stack: two slightly detuned saws + a sub-octave
    // square wave so the resonant filter sweep has thick upper harmonics to chew on,
    // plus a clean fundamental sine sub underneath so low end never drops out
    // when the wobble filter closes.
    final wobSaw1 = SawtoothOscillator(
      frequency: .signal(bassFreq.outlet.mult(0.994, interpTime: 0.0).outlet),
    );
    final wobSaw2 = SawtoothOscillator(
      frequency: .signal(bassFreq.outlet.mult(1.006, interpTime: 0.0).outlet),
    );
    final wobSquare = SquareOscillator(
      frequency: .signal(bassFreq.outlet),
    );
    final subSine = SineOscillator(frequency: .signal(bassFreq.outlet));

    final wobOscMix =
        wobSaw1.outlet.mult(0.40).outlet +
        wobSaw2.outlet.mult(0.40).outlet +
        wobSquare.outlet.mult(0.30).outlet;

    // Resonant lowpass filter BEFORE tube saturation: the high Q (`3.2`) makes
    // the LFO sweep talk like a vowel ("wah/wob"), and driving that resonant
    // peak into `Saturator.tube` gives it the classic gnarly jump-up/jungle bark.
    final wobFilter = SvfFilter(
      input: wobOscMix,
      cutoff: .signal(wobbleLfo.outlet),
      resonance: const .value(3.2),
    );
    final wobDriven = Saturator.tube(
      wobFilter.lowpass,
      drive: const .value(2.8),
      bias: const .value(0.18),
    );

    // Combine the talking LFO midrange with a steady clean sine sub
    final bassCombined =
        wobDriven.outlet.mult(0.55).outlet + subSine.outlet.mult(0.65).outlet;

    // Sidechain-duck the bass under the kick so the kick punch cuts right through
    final bassDucked = Compressor.mono(
      bassCombined,
      sidechain: kick.outlet,
      threshold: const .value(-20.0),
      ratio: const .value(7.0),
      attack: const .value(0.002),
      release: const .value(0.110),
      knee: const .value(3.0),
    );

    // Stereo staging: drums through the breakbeat saturator, then summed with
    // the sub/Reese bass so the low sub stays clean and weighty.
    final shuffHatPan = StereoPan(
      input: shuffHat.outlet.mult(0.48).outlet,
      pan: const .value(-0.22),
    );
    final metalRidePan = StereoPan(
      input: metalRide.outlet.mult(0.34).outlet,
      pan: const .value(0.32),
    );
    final clapPan = StereoPan(
      input: clap.outlet.mult(0.85).outlet,
      pan: const .value(0.18),
    );

    final drumCenter = kick.outlet + snare.outlet;
    final drumLeft =
        drumCenter + shuffHatPan.left + metalRidePan.left + clapPan.left;
    final drumRight =
        drumCenter + shuffHatPan.right + metalRidePan.right + clapPan.right;

    final drumBusSat = Saturator.stereo(
      drumLeft,
      drumRight,
      drive: const .value(1.35),
      mix: const .value(0.75),
      mode: .tanh,
    );

    final bassScaled = bassDucked.outlet.mult(0.68).outlet;
    final masterLeft = drumBusSat.outlets[0] + bassScaled;
    final masterRight = drumBusSat.outlets[1] + bassScaled;

    return Mult.stereo(
      leftInput: masterLeft,
      rightInput: masterRight,
      value: const .value(0.58),
    );
  },
);
