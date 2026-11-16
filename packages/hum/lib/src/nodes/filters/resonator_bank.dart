import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Preset vocal vowel formants for [ResonatorBank.formant].
///
/// Based on classical Peterson & Barney acoustic vocal tract formant data.
enum Vowel(final List<double> frequencies, final List<double> formantGains) {
  /// Open vowel `/a/` (as in "father").
  /// Formants: ~800 Hz, 1200 Hz, 2500 Hz, 3500 Hz.
  a([800.0, 1200.0, 2500.0, 3500.0], [1.0, 0.7, 0.4, 0.2]),

  /// Mid-front vowel `/e/` (as in "bed").
  /// Formants: ~530 Hz, 1840 Hz, 2480 Hz, 3500 Hz.
  e([530.0, 1840.0, 2480.0, 3500.0], [1.0, 0.8, 0.5, 0.2]),

  /// High-front vowel `/i/` (as in "see").
  /// Formants: ~270 Hz, 2290 Hz, 3010 Hz, 3500 Hz.
  i([270.0, 2290.0, 3010.0, 3500.0], [1.0, 0.6, 0.4, 0.2]),

  /// Mid-back rounded vowel `/o/` (as in "boat").
  /// Formants: ~500 Hz, 1000 Hz, 2500 Hz, 3500 Hz.
  o([500.0, 1000.0, 2500.0, 3500.0], [1.0, 0.7, 0.3, 0.15]),

  /// High-back rounded vowel `/u/` (as in "boot").
  /// Formants: ~300 Hz, 870 Hz, 2240 Hz, 3500 Hz.
  u([300.0, 870.0, 2240.0, 3500.0], [1.0, 0.5, 0.25, 0.1]),
}

typedef ResonatorBankParams = ({
  List<double> frequencies,
  List<double>? gains,
  List<double>? pans,
  double? frequencyMultiplier,
  double? q,
  double? brightness,
  double? spread,
  double? mix,
});

/// A parallel acoustic filter bank composed of multiple tuned, second-order
/// bandpass resonators with stereo spatialization and high-Q ringing.
///
/// Unlike sequential (series) filters which multiply transfer functions and
/// steepen attenuation slopes, a parallel resonator bank sums the outputs of
/// multiple tuned bandpass modes ($H_1 + H_2 + \dots$).
///
/// This models physical resonant structures:
/// - Acoustic bodies (strings, cello cavities, bells, singing bowls).
/// - Vocal tract formants (producing human choir / vowel tones from noise or buzz).
/// - Modal chords and microtonal drone textures.
///
/// Uses 2-pole State Variable Filters (SVF) configured for **unit-gain bandpass**
/// at resonance ($0\text{ dB}$ peak gain), ensuring unconditional numerical stability
/// and zero volume explosion even at extreme resonance ($Q \ge 100$).
///
/// https://www.soundonsound.com/techniques/formant-synthesis
/// https://en.wikipedia.org/wiki/Filter_bank
class const ResonatorBank({
  required final List<Outlet> channels,
  required final List<double> frequencies,
  final List<double>? gains,
  final List<double>? pans,
  final ControlParam<double> frequencyMultiplier = const .value(1.0),
  final ControlParam<double> q = const .value(20.0),
  final ControlParam<double> brightness = const .value(1.0),
  final ControlParam<double> spread = const .value(1.0),
  final ControlParam<double> mix = const .value(1.0),
}) extends AudioNode<ResonatorBankProcessor> {
  /// Creates a [ResonatorBank] driven by a single mono audio [input].
  factory mono(
    Outlet input, {
    required List<double> frequencies,
    List<double>? gains,
    List<double>? pans,
    ControlParam<double> frequencyMultiplier = const .value(1.0),
    ControlParam<double> q = const .value(20.0),
    ControlParam<double> brightness = const .value(1.0),
    ControlParam<double> spread = const .value(1.0),
    ControlParam<double> mix = const .value(1.0),
  }) => ResonatorBank(
    channels: [input],
    frequencies: frequencies,
    gains: gains,
    pans: pans,
    frequencyMultiplier: frequencyMultiplier,
    q: q,
    brightness: brightness,
    spread: spread,
    mix: mix,
  );

  /// Creates a [ResonatorBank] driven by stereo audio inputs [left] and [right].
  factory stereo(
    Outlet left,
    Outlet right, {
    required List<double> frequencies,
    List<double>? gains,
    List<double>? pans,
    ControlParam<double> frequencyMultiplier = const .value(1.0),
    ControlParam<double> q = const .value(20.0),
    ControlParam<double> brightness = const .value(1.0),
    ControlParam<double> spread = const .value(1.0),
    ControlParam<double> mix = const .value(1.0),
  }) => ResonatorBank(
    channels: [left, right],
    frequencies: frequencies,
    gains: gains,
    pans: pans,
    frequencyMultiplier: frequencyMultiplier,
    q: q,
    brightness: brightness,
    spread: spread,
    mix: mix,
  );

  /// Creates a harmonic series resonator bank with frequencies $f_k = k \times f_0$.
  ///
  /// Individual harmonic gains decay exponentially according to [rolloff]
  /// ($g_k = (1 / k)^\text{rolloff}$).
  factory harmonics(
    Outlet input, {
    required double fundamental,
    int count = 8,
    double rolloff = 1.0,
    ControlParam<double> frequencyMultiplier = const .value(1.0),
    ControlParam<double> q = const .value(20.0),
    ControlParam<double> brightness = const .value(1.0),
    ControlParam<double> spread = const .value(1.0),
    ControlParam<double> mix = const .value(1.0),
  }) {
    if (count <= 0) throw ArgumentError.value(count, 'count', 'Must be > 0');

    final freqs = [
      for (int k = 1; k <= count; k++) fundamental * k,
    ];

    final harmonicGains = [
      for (int k = 1; k <= count; k++) 1.0 / math.pow(k.toDouble(), rolloff),
    ];

    return .mono(
      input,
      frequencies: freqs,
      gains: harmonicGains,
      frequencyMultiplier: frequencyMultiplier,
      q: q,
      brightness: brightness,
      spread: spread,
      mix: mix,
    );
  }

  /// Creates a chord resonator bank tuned to specific musical [notes].
  factory chord(
    Outlet input, {
    required List<Note> notes,
    ControlParam<double> frequencyMultiplier = const .value(1.0),
    ControlParam<double> q = const .value(30.0),
    ControlParam<double> brightness = const .value(1.0),
    ControlParam<double> spread = const .value(1.0),
    ControlParam<double> mix = const .value(1.0),
  }) {
    if (notes.isEmpty) throw ArgumentError('notes list must not be empty');
    final freqs = [for (final n in notes) n.hz];

    return .mono(
      input,
      frequencies: freqs,
      frequencyMultiplier: frequencyMultiplier,
      q: q,
      brightness: brightness,
      spread: spread,
      mix: mix,
    );
  }

  /// Creates a vocal tract formant resonator bank matching vowel [vowel].
  ///
  /// Exciting this resonator with noise, a rich sawtooth, or impulse trains
  /// produces distinctive vocal timbre characteristics.
  factory formant(
    Outlet input, {
    Vowel vowel = .a,
    ControlParam<double> frequencyMultiplier = const .value(1.0),
    ControlParam<double> q = const .value(15.0),
    ControlParam<double> brightness = const .value(1.0),
    ControlParam<double> spread = const .value(0.5),
    ControlParam<double> mix = const .value(1.0),
  }) {
    return .mono(
      input,
      frequencies: vowel.frequencies,
      gains: vowel.formantGains,
      frequencyMultiplier: frequencyMultiplier,
      q: q,
      brightness: brightness,
      spread: spread,
      mix: mix,
    );
  }

  static const frequencyMultiplierInlet = 0;
  static const qInlet = 1;
  static const brightnessInlet = 2;
  static const spreadInlet = 3;
  static const mixInlet = 4;
  static const audioInletOffset = 5;

  int get numInputChannels => channels.length;

  @override
  List<Inlet> get inlets => [
    Inlet(
      node: this,
      index: frequencyMultiplierInlet,
      source: frequencyMultiplier.outletOrNull,
    ),
    Inlet(node: this, index: qInlet, source: q.outletOrNull),
    Inlet(node: this, index: brightnessInlet, source: brightness.outletOrNull),
    Inlet(node: this, index: spreadInlet, source: spread.outletOrNull),
    Inlet(node: this, index: mixInlet, source: mix.outletOrNull),
    for (int i = 0; i < channels.length; i++)
      Inlet(node: this, index: audioInletOffset + i, source: channels[i]),
  ];

  @override
  List<Outlet> get outlets => [
    Outlet(node: this, index: 0), // Left
    Outlet(node: this, index: 1), // Right
  ];

  Outlet get left => outlets[0];
  Outlet get right => outlets[1];
  Outlet get outlet => outlets[0];

  @override
  List<Object?> get fixedProps => [frequencies.length];

  @override
  List<Object?> get dynamicProps => [
    frequencies,
    gains,
    pans,
    frequencyMultiplier,
    q,
    brightness,
    spread,
    mix,
  ];

  @override
  ResonatorBankProcessor createProcessor() => ResonatorBankProcessor(
    numInputChannels: numInputChannels,
    frequencies: frequencies,
    gains: gains,
    pans: pans,
    frequencyMultiplier: frequencyMultiplier.valueOrNull,
    q: q.valueOrNull,
    brightness: brightness.valueOrNull,
    spread: spread.valueOrNull,
    mix: mix.valueOrNull,
  );

  @override
  ResonatorBankParams get params => (
    frequencies: frequencies,
    gains: gains,
    pans: pans,
    frequencyMultiplier: frequencyMultiplier.valueOrNull,
    q: q.valueOrNull,
    brightness: brightness.valueOrNull,
    spread: spread.valueOrNull,
    mix: mix.valueOrNull,
  );

  @override
  List<AudioNodeError> get errors => [
    if (channels.isEmpty)
      const AudioNodeError(
        message: 'ResonatorBank requires at least one audio input channel',
      ),
    if (frequencies.isEmpty)
      const AudioNodeError(
        message: 'ResonatorBank requires at least one resonant frequency',
      ),
    for (final f in frequencies)
      if (f <= 0.0)
        AudioNodeParamError(
          param: 'frequencies',
          error: 'Resonant frequency must be positive (> 0.0 Hz), received: $f',
        ),
  ];
}

/// Processor implementing parallel 2-pole SVF bandpass resonators with stereo panning.
class ResonatorBankProcessor({
  required final int numInputChannels,
  required List<double> frequencies,
  List<double>? gains,
  List<double>? pans,
  var double? frequencyMultiplier = 1.0,
  var double? q = 20.0,
  var double? brightness = 1.0,
  var double? spread = 1.0,
  var double? mix = 1.0,
}) implements AudioProcessor {
  List<double> _frequencies = List.of(frequencies);
  List<double> _baseGains = _normalizeGains(frequencies.length, gains);
  List<double> _basePans = _generatePans(frequencies.length, pans);

  // SVF state variables per resonator mode:
  // s1[k] and s2[k]
  Float64List _s1 = Float64List(frequencies.length);
  Float64List _s2 = Float64List(frequencies.length);

  // Pre-allocated coefficient buffers for block processing (zero heap allocation)
  late Float64List _a1Coeffs = Float64List(_frequencies.length);
  late Float64List _a2Coeffs = Float64List(_frequencies.length);
  late Float64List _gCoeffs = Float64List(_frequencies.length);
  late Float64List _kCoeffs = Float64List(_frequencies.length);
  late Float64List _gainLCoeffs = Float64List(_frequencies.length);
  late Float64List _gainRCoeffs = Float64List(_frequencies.length);

  int get modeCount => _frequencies.length;

  static List<double> _normalizeGains(int count, List<double>? userGains) {
    if (userGains != null && userGains.length == count) {
      return List.of(userGains);
    }
    // Default normalization factor so sum doesn't clip when multiple modes ring
    final norm = 1.0 / math.sqrt(math.max(1, count).toDouble());
    return List.filled(count, norm);
  }

  static List<double> _generatePans(int count, List<double>? userPans) {
    if (userPans != null && userPans.length == count) {
      return List.of(userPans);
    }
    if (count <= 1) return const [0.0];

    // Interleave modes: fundamental center, odd modes left, even modes right
    final pans = List.filled(count, 0.0);
    pans[0] = 0.0;
    for (int k = 1; k < count; k++) {
      final sign = (k % 2 == 1) ? -1.0 : 1.0;
      final step = ((k + 1) ~/ 2) / (count / 2.0);
      pans[k] = (sign * step).fastClamp(-1.0, 1.0);
    }
    return pans;
  }

  @override
  void update(Object params) {
    final p = params as ResonatorBankParams;

    if (_frequencies.length != p.frequencies.length) {
      _frequencies = List.of(p.frequencies);
      final count = _frequencies.length;
      _s1 = Float64List(count);
      _s2 = Float64List(count);
      _a1Coeffs = Float64List(count);
      _a2Coeffs = Float64List(count);
      _gCoeffs = Float64List(count);
      _kCoeffs = Float64List(count);
      _gainLCoeffs = Float64List(count);
      _gainRCoeffs = Float64List(count);
    } else {
      _frequencies.setAll(0, p.frequencies);
    }

    _baseGains = _normalizeGains(_frequencies.length, p.gains);
    _basePans = _generatePans(_frequencies.length, p.pans);
    frequencyMultiplier = p.frequencyMultiplier;
    q = p.q;
    brightness = p.brightness;
    spread = p.spread;
    mix = p.mix;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final length = context.vectorSize;
    final sampleRate = context.sampleRate.toDouble();
    final piOverSr = math.pi / sampleRate;
    final maxCutoff = sampleRate * 0.499;

    final staticPitch = frequencyMultiplier;
    final staticQ = q;
    final staticBrightness = brightness;
    final staticSpread = spread;
    final staticMix = mix;

    final pitchBuf = staticPitch == null
        ? inputs[ResonatorBank.frequencyMultiplierInlet]
        : null;
    final qBuf = staticQ == null ? inputs[ResonatorBank.qInlet] : null;
    final brightBuf = staticBrightness == null
        ? inputs[ResonatorBank.brightnessInlet]
        : null;
    final spreadBuf = staticSpread == null
        ? inputs[ResonatorBank.spreadInlet]
        : null;
    final mixBuf = staticMix == null ? inputs[ResonatorBank.mixInlet] : null;

    final defaultPitch = staticPitch ?? 1.0;
    final defaultQ = staticQ ?? 20.0;
    final defaultBrightness = staticBrightness ?? 1.0;
    final defaultSpread = staticSpread ?? 1.0;
    final defaultMix = staticMix ?? 1.0;

    final inL = inputs[ResonatorBank.audioInletOffset];
    final inR = numInputChannels > 1
        ? inputs[ResonatorBank.audioInletOffset + 1]
        : inL;

    final outL = outputs[0];
    final outR = outputs[1];

    final isStaticParams =
        pitchBuf == null &&
        qBuf == null &&
        brightBuf == null &&
        spreadBuf == null &&
        mixBuf == null;

    final count = _frequencies.length;
    final s1 = _s1;
    final s2 = _s2;

    if (isStaticParams) {
      // Fast path: block-constant tuning, Q, and stereo pan coefficients
      final baseQ = defaultQ.fastClamp(0.5, 500.0);
      final pitchMult = defaultPitch.fastClamp(0.01, 100.0);
      final bright = defaultBrightness.fastClamp(0.0, 2.0);
      final curSpread = defaultSpread.fastClamp(0.0, 1.0);
      final (dryGain, wetGain) = equalPowerMix(defaultMix);

      // Pre-compute per-mode SVF coefficients and stereo weights once for the block into pre-allocated arrays
      final a1Coeffs = _a1Coeffs;
      final a2Coeffs = _a2Coeffs;
      final gCoeffs = _gCoeffs;
      final kCoeffs = _kCoeffs;
      final gainLCoeffs = _gainLCoeffs;
      final gainRCoeffs = _gainRCoeffs;

      for (int k = 0; k < count; k++) {
        final f = (_frequencies[k] * pitchMult).fastClamp(10.0, maxCutoff);
        // Brightness rolloff: higher modes scale Q proportionally
        final modeQ = (baseQ * math.pow(bright, k * 0.5)).fastClamp(0.5, 500.0);

        final g = math.tan(piOverSr * f);
        final kDamp = 1.0 / modeQ;
        final a1 = 1.0 / (1.0 + g * (g + kDamp));
        final a2 = g * a1;

        a1Coeffs[k] = a1;
        a2Coeffs[k] = a2;
        gCoeffs[k] = g;
        kCoeffs[k] = kDamp;

        // Stereo pan weights
        final pan = (_basePans[k] * curSpread).fastClamp(-1.0, 1.0);
        final pL = equalPowerGainLeft(pan);
        final pR = equalPowerGainRight(pan);
        final modeGain = _baseGains[k];
        gainLCoeffs[k] = pL * modeGain;
        gainRCoeffs[k] = pR * modeGain;
      }

      for (int i = 0; i < length; i++) {
        // Mono excitation signal driving the resonators
        final x = 0.5 * (inL[i] + inR[i]);
        double accumL = 0.0;
        double accumR = 0.0;

        for (int k = 0; k < count; k++) {
          final a1 = a1Coeffs[k];
          final a2 = a2Coeffs[k];
          final g = gCoeffs[k];
          final kDamp = kCoeffs[k];

          final state1 = s1[k];
          final state2 = s2[k];

          final v1 = a1 * state1 + a2 * (x - state2);
          final v2 = state2 + g * v1;
          s1[k] = 2.0 * v1 - state1;
          s2[k] = 2.0 * v2 - state2;

          // Unit-gain bandpass
          final bp = kDamp * v1;

          accumL += bp * gainLCoeffs[k];
          accumR += bp * gainRCoeffs[k];
        }

        // Dry/wet blend
        outL[i] = (inL[i] * dryGain + accumL * wetGain);
        outR[i] = (inR[i] * dryGain + accumR * wetGain);
      }
    } else {
      // Audio-rate modulated path
      for (int i = 0; i < length; i++) {
        final x = 0.5 * (inL[i] + inR[i]);
        final pitchMult = (pitchBuf != null ? pitchBuf[i] : defaultPitch)
            .fastClamp(0.01, 100.0);
        final baseQ = (qBuf != null ? qBuf[i] : defaultQ).fastClamp(0.5, 500.0);
        final bright = (brightBuf != null ? brightBuf[i] : defaultBrightness)
            .fastClamp(0.0, 2.0);
        final curSpread = (spreadBuf != null ? spreadBuf[i] : defaultSpread)
            .fastClamp(0.0, 1.0);
        final curMix = (mixBuf != null ? mixBuf[i] : defaultMix);
        final dryGain = equalPowerDry(curMix);
        final wetGain = equalPowerWet(curMix);

        double accumL = 0.0;
        double accumR = 0.0;

        for (int k = 0; k < count; k++) {
          final f = (_frequencies[k] * pitchMult).fastClamp(10.0, maxCutoff);
          final modeQ = (baseQ * math.pow(bright, k * 0.5)).fastClamp(
            0.5,
            500.0,
          );

          final g = math.tan(piOverSr * f);
          final kDamp = 1.0 / modeQ;
          final a1 = 1.0 / (1.0 + g * (g + kDamp));
          final a2 = g * a1;

          final state1 = s1[k];
          final state2 = s2[k];

          final v1 = a1 * state1 + a2 * (x - state2);
          final v2 = state2 + g * v1;
          s1[k] = 2.0 * v1 - state1;
          s2[k] = 2.0 * v2 - state2;

          final bp = kDamp * v1;

          final pan = (_basePans[k] * curSpread).fastClamp(-1.0, 1.0);
          final pL = equalPowerGainLeft(pan);
          final pR = equalPowerGainRight(pan);
          final modeGain = _baseGains[k];

          accumL += bp * (pL * modeGain);
          accumR += bp * (pR * modeGain);
        }

        outL[i] = (inL[i] * dryGain + accumL * wetGain);
        outR[i] = (inR[i] * dryGain + accumR * wetGain);
      }
    }

    // Anti-denormal flush (stops tiny floats making CPU brrrr)
    for (int k = 0; k < count; k++) {
      if (s1[k].abs() < 1e-15) s1[k] = 0.0;
      if (s2[k].abs() < 1e-15) s2[k] = 0.0;
    }
  }
}

extension OutletResonatorBankExtension on Outlet {
  /// Applies a parallel tuned resonator bank to this outlet.
  ResonatorBank resonate({
    required List<double> frequencies,
    List<double>? gains,
    List<double>? pans,
    ControlParam<double> frequencyMultiplier = const .value(1.0),
    ControlParam<double> q = const .value(20.0),
    ControlParam<double> brightness = const .value(1.0),
    ControlParam<double> spread = const .value(1.0),
    ControlParam<double> mix = const .value(1.0),
  }) => .mono(
    this,
    frequencies: frequencies,
    gains: gains,
    pans: pans,
    frequencyMultiplier: frequencyMultiplier,
    q: q,
    brightness: brightness,
    spread: spread,
    mix: mix,
  );
}
