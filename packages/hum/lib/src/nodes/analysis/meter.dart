import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Linear peak and RMS level snapshot for a single audio channel over the most
/// recent telemetry window.
class const ChannelLevel({
  /// Maximum absolute sample amplitude observed since the previous flush.
  required final double peak,

  /// Root-mean-square amplitude observed since the previous flush.
  required final double rms,
}) {
  /// Peak amplitude converted to decibels full-scale (dBFS).
  double get peakDb => gainToDb(peak);

  /// RMS amplitude converted to decibels full-scale (dBFS).
  double get rmsDb => gainToDb(rms);

  /// Whether the channel reached or exceeded digital full-scale (`>= 1.0`).
  bool get clipped => peak >= 1.0;

  @override
  String toString() =>
      'ChannelLevel(peak: ${peak.toStringAsFixed(4)}, rms: ${rms.toStringAsFixed(4)})';
}

/// Multi-channel peak and RMS telemetry reading emitted by [Meter].
///
/// Each reading covers the exact window of samples processed since the
/// previous telemetry flush so transient peaks are never missed. Smoothing,
/// peak-hold, and VU ballistics belong in host/UI code layered on top.
class const MeterReading(final List<ChannelLevel> channels) {
  /// First channel reading (convenience for mono meters).
  ChannelLevel get mono => channels.first;

  /// Left channel reading (convenience for stereo meters).
  ChannelLevel get left => channels[0];

  /// Right channel reading (convenience for stereo meters).
  ChannelLevel get right => channels[1];

  /// Maximum linear peak across all metered channels.
  double get peak {
    double maxPeak = 0.0;
    for (final ch in channels) {
      if (ch.peak > maxPeak) maxPeak = ch.peak;
    }
    return maxPeak;
  }

  /// Maximum linear RMS across all metered channels.
  double get rms {
    double maxRms = 0.0;
    for (final ch in channels) {
      if (ch.rms > maxRms) maxRms = ch.rms;
    }
    return maxRms;
  }

  /// Maximum peak across all channels in dBFS.
  double get peakDb => gainToDb(peak);

  /// Maximum RMS across all channels in dBFS.
  double get rmsDb => gainToDb(rms);

  /// Whether any channel reached or exceeded digital full-scale (`>= 1.0`).
  bool get clipped => peak >= 1.0;

  @override
  String toString() => 'MeterReading($channels)';
}

/// A multi-channel inline passthrough level meter that emits per-window peak
/// and RMS telemetry via [TelemetryNode].
///
/// Can be spliced inline (`reverb -> meter -> out`) with a single graph root,
/// or attached as a side-tap via `setGraph(roots: [out, meter])`.
class Meter({
  required final List<Outlet> inputs,
}) extends AudioNode<MeterProcessor> with TelemetryNode<MeterReading> {
  /// Creates a single-channel [Meter].
  factory mono({required Outlet input}) => Meter(inputs: [input]);

  /// Creates a stereo [Meter].
  factory stereo({required Outlet left, required Outlet right}) =>
      Meter(inputs: [left, right]);

  /// Number of channels metered by this node.
  int get numChannels => inputs.length;

  @override
  List<Inlet> get inlets => [
    for (int i = 0; i < inputs.length; i++)
      Inlet(node: this, index: i, source: inputs[i]),
  ];

  @override
  List<Outlet> get outlets => [
    for (int i = 0; i < inputs.length; i++) Outlet(node: this, index: i),
  ];

  /// Passthrough outlet for mono usage.
  Outlet get outlet => outlets.first;

  /// Left passthrough outlet for stereo usage.
  Outlet get left => outlets[0];

  /// Right passthrough outlet for stereo usage.
  Outlet get right => outlets[1];

  @override
  MeterProcessor createProcessor() =>
      MeterProcessor(numChannels: inputs.length);

  @override
  Object get params => ();

  @override
  List<AudioNodeError> get errors => [
    if (inputs.isEmpty)
      const AudioNodeParamError(param: 'inputs', error: 'must not be empty'),
  ];

  @override
  List<Object?> get fixedProps => [inputs.length];

  @override
  List<Object?> get dynamicProps => const [];

  @override
  MeterReading decodeTelemetry(Float32List data) => MeterReading([
    for (int c = 0; c < inputs.length; c++)
      ChannelLevel(peak: data[c * 2], rms: data[c * 2 + 1]),
  ]);
}

/// Runtime processor for [Meter].
///
/// Performs a single-pass passthrough copy + peak/sum-of-squares accumulation
/// with zero allocations, computing `sqrt` only on throttled telemetry flushes.
class MeterProcessor({
  required final int numChannels,
}) implements TelemetryProcessor {
  final Float64List _peaks = Float64List(numChannels);
  final Float64List _sumSquares = Float64List(numChannels);
  int _sampleCount = 0;

  @override
  int get telemetryLength => numChannels * 2;

  @override
  void update(Object params) {}

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final int n = context.vectorSize;
    for (int ch = 0; ch < numChannels; ch++) {
      final inp = inputs[ch];
      final out = outputs[ch];
      double peak = _peaks[ch];
      double sumSq = _sumSquares[ch];

      for (int i = 0; i < n; i++) {
        final double s = inp[i];
        out[i] = s;
        final double abs = s < 0.0 ? -s : s;
        if (abs > peak) peak = abs;
        sumSq += s * s;
      }

      _peaks[ch] = peak;
      _sumSquares[ch] = sumSq;
    }
    _sampleCount += n;
  }

  @override
  bool writeTelemetry(Float32List out, int offset) {
    final int count = _sampleCount;
    if (count == 0) return false;

    final double invCount = 1.0 / count;
    for (int ch = 0; ch < numChannels; ch++) {
      final int base = offset + ch * 2;
      out[base] = _peaks[ch];
      out[base + 1] = math.sqrt(_sumSquares[ch] * invCount);
      _peaks[ch] = 0.0;
      _sumSquares[ch] = 0.0;
    }

    _sampleCount = 0;
    return true;
  }
}

/// Convenience extension for splicing a mono [Meter] onto an [Outlet].
extension MeterExtension on Outlet {
  /// Inserts a mono passthrough [Meter] on this outlet.
  Meter meter() => Meter.mono(input: this);
}
