import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Parameter bag for updating a [SamplePlayerProcessor] in-place.
typedef SamplePlayerParams = ({
  BufferId? bufferId,
  double? rate,
  bool? loop,
  int? loopStart,
  int? loopEnd,
});

/// Plays back an [AudioBuffer] loaded into the [AudioEngine] via
/// [AudioHost.loadBuffer].
///
/// Features:
/// - **One-shot or looped playback** between [loopStart] and [loopEnd]
/// - **Rising-edge [trigger]** retriggering (or auto-play when [trigger] is
///   omitted)
/// - **Automatic sample-rate compensation** (`buffer.sampleRate / context.sampleRate`)
/// - **Audio-rate [rate] modulation** (including negative rates for reverse
///   playback) with 4-point cubic Hermite interpolation
/// - **Zero-rebuild buffer swapping** via [AudioHost.update] or [AudioHost.setGraph]
///   when the replacement buffer has the same channel count
class SamplePlayer({
  /// Handle to the audio buffer registered with [AudioHost.loadBuffer].
  required final BufferHandle buffer,

  /// Optional rising-edge trigger (`<= 0` -> `> 0`) to start/retrigger
  /// playback. If `null`, playback starts immediately on first process block.
  final Outlet? trigger,

  /// Playback speed multiplier (`1.0` = original pitch, `2.0` = octave up,
  /// `-1.0` = reverse). Automatically compensated for sample rate differences.
  final ControlParam<double> rate = const .value(1.0),

  /// Whether playback wraps seamlessly between [loopStart] and [loopEnd].
  final bool loop = false,

  /// Start frame of the playback / loop region (inclusive, default `0`).
  final int loopStart = 0,

  /// End frame of the playback / loop region (exclusive, defaults to the
  /// buffer's full length).
  final int? loopEnd,
}) extends AudioNode<SamplePlayerProcessor> {
  static const triggerInlet = 0;
  static const rateInlet = 1;

  /// Number of output channels declared by this player.
  int get numChannels => buffer.numChannels;

  @override
  List<Inlet> get inlets => [
    Inlet(node: this, index: triggerInlet, source: trigger),
    Inlet(node: this, index: rateInlet, source: rate.outletOrNull),
  ];

  @override
  late final List<Outlet> outlets = [
    for (int i = 0; i < buffer.numChannels; i++) Outlet(node: this, index: i),
  ];

  /// Mono output outlet (first channel).
  Outlet get outlet => outlets.first;

  /// Left output outlet for stereo buffers.
  Outlet get left => outlets[0];

  /// Right output outlet for stereo buffers.
  Outlet get right => outlets[1];

  @override
  SamplePlayerProcessor createProcessor() => SamplePlayerProcessor(
    bufferId: buffer.id,
    numChannels: buffer.numChannels,
    hasTrigger: trigger != null,
    rate: rate.valueOrNull ?? 1.0,
    hasRateCv: rate.outletOrNull != null,
    loop: loop,
    loopStart: loopStart,
    loopEnd: loopEnd,
  );

  @override
  List<AudioNodeError> get errors => [
    if (buffer.numChannels <= 0)
      const AudioNodeParamError(
        param: 'buffer',
        error: 'must have at least one channel',
      ),
    if (loopStart < 0)
      const AudioNodeParamError(
        param: 'loopStart',
        error: 'must be non-negative',
      ),
    if (loopEnd != null && loopEnd! <= loopStart)
      const AudioNodeParamError(
        param: 'loopEnd',
        error: 'must be greater than loopStart',
      ),
  ];

  @override
  List<Object?> get fixedProps => [
    buffer.numChannels,
    trigger != null,
    rate.outletOrNull != null,
  ];

  @override
  List<Object?> get dynamicProps => [
    buffer.id,
    rate.valueOrNull,
    loop,
    loopStart,
    loopEnd,
  ];

  @override
  Object get params => (
    bufferId: buffer.id,
    rate: rate.valueOrNull,
    loop: loop,
    loopStart: loopStart,
    loopEnd: loopEnd,
  );
}

/// Runtime processor for [SamplePlayer].
class SamplePlayerProcessor({
  required BufferId bufferId,
  required final int numChannels,
  final bool hasTrigger = false,
  double rate = 1.0,
  final bool hasRateCv = false,
  bool loop = false,
  int loopStart = 0,
  int? loopEnd,
}) implements BufferAwareProcessor {
  BufferId _bufferId = bufferId;
  double _rate = rate;
  bool _loop = loop;
  int _loopStart = loopStart;
  int? _loopEnd = loopEnd;

  BufferLookup? _lookup;
  AudioBuffer? _buffer;

  // Auto-play immediately when no trigger inlet is wired.
  bool _playing = !hasTrigger;
  bool _initializedPosition = false;
  double _position = 0.0;
  double _prevTrigger = 0.0;

  /// Whether playback is currently active.
  bool get isPlaying => _playing;

  /// Current fractional playhead position in buffer frames.
  double get position => _position;

  @override
  void bindBuffers(BufferLookup lookup) {
    _lookup = lookup;
    _buffer = lookup(_bufferId);
  }

  @override
  void update(Object params) {
    if (params case final SamplePlayerParams p) {
      if (p.rate != null) _rate = p.rate!;
      if (p.loop != null) _loop = p.loop!;
      if (p.loopStart != null) _loopStart = p.loopStart!;
      if (p.loopEnd != null) _loopEnd = p.loopEnd;

      if (p.bufferId != null && p.bufferId != _bufferId) {
        _bufferId = p.bufferId!;
        _buffer = _lookup?.call(_bufferId);
        _initializedPosition = false;
        if (!hasTrigger) {
          _playing = true;
        } else {
          _playing = false;
        }
      }
    }
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final int n = context.vectorSize;
    final buf = _buffer;
    if (buf == null || buf.length == 0) {
      for (int ch = 0; ch < numChannels; ch++) {
        outputs[ch].fillRange(0, n, 0.0);
      }
      return;
    }

    final int len = buf.length;
    final int start = _loopStart.clamp(0, len - 1);
    final int end = (_loopEnd ?? len).clamp(start + 1, len);
    final int span = end - start;
    final double srScale = buf.sampleRate / context.sampleRate;

    final trigBuf = hasTrigger ? inputs[SamplePlayer.triggerInlet] : null;
    final rateBuf = hasRateCv ? inputs[SamplePlayer.rateInlet] : null;

    if (!_initializedPosition && _playing) {
      final double initialRate = rateBuf != null ? rateBuf[0] : _rate;
      _position = initialRate < 0.0 ? (end - 1).toDouble() : start.toDouble();
      _initializedPosition = true;
    }

    final int bufChannels = buf.numChannels;
    final bool isLooping = _loop;

    for (int i = 0; i < n; i++) {
      final double r = rateBuf != null ? rateBuf[i] : _rate;

      if (trigBuf != null) {
        final double trig = trigBuf[i];
        if (trig > 0.0 && _prevTrigger <= 0.0) {
          _playing = true;
          _initializedPosition = true;
          _position = r < 0.0 ? (end - 1).toDouble() : start.toDouble();
        }
        _prevTrigger = trig;
      }

      if (!_playing) {
        for (int ch = 0; ch < numChannels; ch++) {
          outputs[ch][i] = 0.0;
        }
        continue;
      }

      final int idx = _position.floor();
      final double frac = _position - idx;

      int i0 = idx - 1;
      int i1 = idx;
      int i2 = idx + 1;
      int i3 = idx + 2;

      if (isLooping) {
        i0 = start + ((i0 - start) % span + span) % span;
        i1 = start + ((i1 - start) % span + span) % span;
        i2 = start + ((i2 - start) % span + span) % span;
        i3 = start + ((i3 - start) % span + span) % span;
      } else {
        if (i0 < 0) i0 = 0;
        if (i0 >= len) i0 = len - 1;
        if (i1 < 0) i1 = 0;
        if (i1 >= len) i1 = len - 1;
        if (i2 < 0) i2 = 0;
        if (i2 >= len) i2 = len - 1;
        if (i3 < 0) i3 = 0;
        if (i3 >= len) i3 = len - 1;
      }

      for (int ch = 0; ch < numChannels; ch++) {
        final src = buf[ch % bufChannels];
        final double y0 = src[i0];
        final double y1 = src[i1];
        final double y2 = src[i2];
        final double y3 = src[i3];

        // 4-point cubic Hermite interpolation.
        final double c0 = y1;
        final double c1 = 0.5 * (y2 - y0);
        final double c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
        final double c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
        outputs[ch][i] = ((c3 * frac + c2) * frac + c1) * frac + c0;
      }

      _position += r * srScale;

      if (isLooping) {
        if (_position >= end) {
          _position = start + (_position - start) % span;
        } else if (_position < start) {
          _position = start + ((_position - start) % span + span) % span;
        }
      } else if (_position >= end || _position < start) {
        _playing = false;
      }
    }
  }
}
