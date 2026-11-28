import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Parameter bag for updating a [WavetableOscillatorProcessor] in-place.
typedef WavetableOscillatorParams = ({
  WavetableHandle? wavetable,
  double? frequency,
  double? position,
});

/// A band-limited multi-frame wavetable oscillator supporting smooth real-time
/// timbre morphing across frames and alias-free octave mipmap crossfading.
///
/// Load a [Wavetable] via `host.loadWavetable(table)` (or wrap a raw
/// [BufferHandle] via [WavetableHandle.fromBuffer]) and pass the resulting
/// [WavetableHandle] to [wavetable].
class WavetableOscillator({
  /// Handle to the wavetable loaded in [AudioEngine].
  required final WavetableHandle wavetable,

  /// Oscillator fundamental frequency in Hz (static or audio-rate CV).
  @override final ControlParam<double> frequency = const .value(440.0),

  /// Normalized morph position across wavetable frames in `[0.0, 1.0]`
  /// (static or audio-rate CV). Ignored for single-frame wavetables.
  final ControlParam<double> position = const .value(0.0),

  /// Initial normalized oscillator phase in `[0.0, 1.0)`.
  final double initialPhase = 0.0,
}) extends OscillatorNode<WavetableOscillatorProcessor> {
  static const freqInlet = 0;
  static const positionInlet = 1;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: freqInlet, source: frequency.outletOrNull),
    Inlet(node: this, index: positionInlet, source: position.outletOrNull),
  ];

  @override
  late final List<Outlet> outlets = [Outlet(node: this, index: 0)];

  @override
  Outlet get outlet => outlets[0];

  @override
  WavetableOscillatorProcessor createProcessor() =>
      WavetableOscillatorProcessor(
        wavetable: wavetable,
        frequency: frequency.valueOrNull,
        position: position.valueOrNull,
        initialPhase: initialPhase,
      );

  @override
  List<AudioNodeError> get errors => [
    if (wavetable.frameSize <= 0)
      const AudioNodeParamError(
        param: 'wavetable',
        error: 'frameSize must be positive',
      ),
    if (wavetable.numFrames <= 0)
      const AudioNodeParamError(
        param: 'wavetable',
        error: 'numFrames must be positive',
      ),
    if (frequency.valueOrNull case final f? when f < 0.0)
      const AudioNodeParamError(
        param: 'frequency',
        error: 'must be non-negative',
      ),
  ];

  @override
  List<Object?> get fixedProps => [
    frequency.outletOrNull != null,
    position.outletOrNull != null,
  ];

  @override
  List<Object?> get dynamicProps => [
    wavetable,
    frequency.valueOrNull,
    position.valueOrNull,
  ];

  @override
  Object get params => (
    wavetable: wavetable,
    frequency: frequency.valueOrNull,
    position: position.valueOrNull,
  );
}

/// Runtime processor for [WavetableOscillator].
class WavetableOscillatorProcessor({
  required WavetableHandle wavetable,
  double? frequency = 440.0,
  double? position = 0.0,
  double initialPhase = 0.0,
}) implements BufferAwareProcessor {
  static const double _invLn2 = 1.4426950408889634;

  WavetableHandle _handle = wavetable;
  double? _frequency = frequency;
  double? _position = position;
  double _phase = initialPhase - initialPhase.floor();

  BufferLookup? _lookup;
  AudioBuffer? _buffer;

  // Precomputed mipmap table geometry for the active wavetable.
  Int32List _mipOffsets = Int32List(0);
  Int32List _mipLengths = Int32List(0);
  int _numMipLevels = 0;

  this {
    _rebuildMipLayout();
  }

  void _rebuildMipLayout() {
    if (!_handle.mipmapped || _handle.frameSize < 8) {
      _numMipLevels = 0;
      return;
    }
    int levels = 0;
    int len = _handle.frameSize;
    while (len >= 8) {
      levels++;
      len >>= 1;
    }
    _mipOffsets = Int32List(levels);
    _mipLengths = Int32List(levels);
    int offset = 0;
    len = _handle.frameSize;
    for (int m = 0; m < levels; m++) {
      _mipOffsets[m] = offset;
      _mipLengths[m] = len;
      offset += len;
      len >>= 1;
    }
    _numMipLevels = levels;
  }

  @override
  void bindBuffers(BufferLookup lookup) {
    _lookup = lookup;
    _buffer = lookup(_handle.buffer.id);
  }

  @override
  void update(Object params) {
    if (params case final WavetableOscillatorParams p) {
      if (p.frequency != null) _frequency = p.frequency;
      if (p.position != null) _position = p.position;
      if (p.wavetable case final next? when next != _handle) {
        _handle = next;
        _buffer = _lookup?.call(next.buffer.id);
        _rebuildMipLayout();
      }
    }
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final out = outputs[0];
    final int n = context.vectorSize;
    final buf = _buffer;
    if (buf == null || buf.length == 0 || _handle.frameSize <= 0) {
      out.fillRange(0, n, 0.0);
      return;
    }

    final double invSr = 1.0 / context.sampleRate;
    final freqBuf = _frequency == null
        ? inputs[WavetableOscillator.freqInlet]
        : null;
    final posBuf = _position == null
        ? inputs[WavetableOscillator.positionInlet]
        : null;

    final int frameSize = _handle.frameSize;
    final int numFrames = _handle.numFrames;
    final bool isMipmapped = _handle.mipmapped && _numMipLevels > 0;
    final bool multiChannelFrames = buf.numChannels >= numFrames;

    double phase = _phase;
    final double staticFreq = _frequency ?? 440.0;
    final double staticPos = (_position ?? 0.0).clamp(0.0, 1.0);

    for (int i = 0; i < n; i++) {
      final double freq = freqBuf != null ? freqBuf[i] : staticFreq;
      final double pos = posBuf != null
          ? posBuf[i].clamp(0.0, 1.0)
          : staticPos;

      final double phaseInc = freq * invSr;

      // Determine adjacent frames to morph between.
      final int frameA;
      final int frameB;
      final double frameFrac;
      if (numFrames <= 1) {
        frameA = 0;
        frameB = 0;
        frameFrac = 0.0;
      } else {
        final double scaledPos = pos * (numFrames - 1);
        frameA = scaledPos.floor().clamp(0, numFrames - 1);
        frameB = (frameA + 1).clamp(0, numFrames - 1);
        frameFrac = scaledPos - frameA;
      }

      final double sampleA;
      final double sampleB;

      if (isMipmapped) {
        // Select octave mipmap level from phase increment (1-octave safety
        // margin so both crossfaded mip levels stay strictly below Nyquist).
        final double absInc = phaseInc < 0.0 ? -phaseInc : phaseInc;
        final double ratio = absInc * frameSize;
        final double mipFloat = ratio > 1.0
            ? (math.log(ratio) * _invLn2).clamp(0.0, (_numMipLevels - 1).toDouble())
            : 0.0;
        final int mipA = mipFloat.floor();
        final int mipB = mipA + 1 < _numMipLevels ? mipA + 1 : mipA;
        final double mipFrac = mipFloat - mipA;

        sampleA = _readMipFrame(buf[frameA], phase, mipA, mipB, mipFrac);
        sampleB = frameB == frameA
            ? sampleA
            : _readMipFrame(buf[frameB], phase, mipA, mipB, mipFrac);
      } else if (multiChannelFrames) {
        sampleA = _readLinearLoop(buf[frameA], 0, frameSize, phase);
        sampleB = frameB == frameA
            ? sampleA
            : _readLinearLoop(buf[frameB], 0, frameSize, phase);
      } else {
        // Concatenated mono Serum/Vital raw buffer fallback.
        final mono = buf[0];
        sampleA = _readLinearLoop(mono, frameA * frameSize, frameSize, phase);
        sampleB = frameB == frameA
            ? sampleA
            : _readLinearLoop(mono, frameB * frameSize, frameSize, phase);
      }

      out[i] = sampleA + (sampleB - sampleA) * frameFrac;

      phase += phaseInc;
      if (phase >= 1.0) {
        phase -= phase.floor();
      } else if (phase < 0.0) {
        phase -= phase.floor();
      }
    }

    _phase = phase;
  }

  @pragma('vm:prefer-inline')
  double _readMipFrame(
    Float32List channel,
    double phase,
    int mipA,
    int mipB,
    double mipFrac,
  ) {
    final double a = _readLinearLoop(
      channel,
      _mipOffsets[mipA],
      _mipLengths[mipA],
      phase,
    );
    if (mipB == mipA || mipFrac == 0.0) return a;
    final double b = _readLinearLoop(
      channel,
      _mipOffsets[mipB],
      _mipLengths[mipB],
      phase,
    );
    return a + (b - a) * mipFrac;
  }

  @pragma('vm:prefer-inline')
  static double _readLinearLoop(
    Float32List data,
    int baseOffset,
    int length,
    double phase,
  ) {
    final double pos = phase * length;
    final int idx0 = pos.floor();
    final double frac = pos - idx0;
    final int idx1 = idx0 + 1 < length ? idx0 + 1 : 0;
    final double y0 = data[baseOffset + idx0];
    final double y1 = data[baseOffset + idx1];
    return y0 + (y1 - y0) * frac;
  }
}
