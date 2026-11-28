import 'dart:async';
import 'dart:typed_data';

import 'package:hum/hum.dart';

/// An interface for [AudioProcessor]s that emit periodic telemetry back to the
/// host / UI isolate (e.g. step playhead, peak/RMS meters, detected pitch, FFT).
///
/// Implementations must write only primitive `float32` values into the
/// engine's pre-allocated buffer with zero heap allocations.
abstract interface class TelemetryProcessor extends AudioProcessor {
  /// Number of `float32` slots this processor writes per telemetry frame.
  int get telemetryLength;

  /// Writes this processor's latest telemetry values into [out] starting at
  /// [offset] (writing [telemetryLength] values).
  ///
  /// Returns `true` if new telemetry was written, or `false` if nothing changed
  /// since the previous flush and transmission can be skipped.
  bool writeTelemetry(Float32List out, int offset);
}

/// A mixin for [AudioNode]s whose runtime processor emits telemetry.
///
/// The node owns the contract for decoding the raw `float32` slice produced on
/// the audio thread into a typed UI-friendly domain value [T].
mixin TelemetryNode<T> {
  /// Decodes a zero-copy [Float32List] view of this node's telemetry floats
  /// into a domain value of type [T].
  T decodeTelemetry(Float32List data);
}

/// Convenience extension to obtain a node's [TelemetryChannel] from a [host].
extension TelemetryNodeExtension<T> on TelemetryNode<T> {
  /// Returns the [TelemetryChannel] for this node on [host], or `null` if this
  /// node is not part of [host]'s currently compiled graph.
  TelemetryChannel<T>? telemetry(AudioHost host) => host.telemetryOf<T>(this);
}

/// A typed telemetry subscription handle owned by an [AudioHost] and keyed by
/// compiled `nodeId`.
///
/// Supports both zero-jitter 60 fps polling ([latest]) and reactive listeners
/// ([stream]). Survives `setGraph()` rebuilds as long as `GraphDiff` preserves
/// the underlying `nodeId`.
class TelemetryChannel<T> {
  final StreamController<T> _controller = StreamController<T>.broadcast();
  T? _latest;
  bool _isClosed = false;

  /// Most recently received decoded telemetry value, or `null` before the
  /// first reading arrives.
  T? get latest => _latest;

  /// Broadcast stream of decoded telemetry readings.
  Stream<T> get stream => _controller.stream;

  /// Whether this channel has been closed (because the node was removed from
  /// the graph or the host was disposed).
  bool get isClosed => _isClosed;

  void _emit(T value) {
    if (_isClosed) return;
    _latest = value;
    if (_controller.hasListener) {
      _controller.add(value);
    }
  }

  Future<void> _close() async {
    if (_isClosed) return;
    _isClosed = true;
    await _controller.close();
  }
}

class _TelemetryEntry<T>(var TelemetryNode<T> node) {
  final TelemetryChannel<T> channel = TelemetryChannel<T>();

  void deliver(Float32List view) {
    channel._emit(node.decodeTelemetry(view));
  }

  void updateNode(Object candidate) {
    if (candidate is TelemetryNode<T>) {
      node = candidate;
    }
  }

  Future<void> close() => channel._close();
}

/// Host-side registry mapping compiled `nodeId`s to active [TelemetryChannel]s.
///
/// Shared by both [SyncAudioHost] and [IsolateAudioHost].
class TelemetryRegistry {
  final Map<int, _TelemetryEntry<dynamic>> _entries = {};

  /// Returns (creating if needed) the [TelemetryChannel] for [node] in
  /// [snapshot], or `null` if [node] is not in [snapshot].
  TelemetryChannel<T>? channelFor<T>(
    GraphSnapshot snapshot,
    TelemetryNode<T> node,
  ) {
    if (node is! AudioNode) return null;
    final nodeId = snapshot.nodeIds[node as AudioNode];
    if (nodeId == null) return null;

    final existing = _entries[nodeId];
    if (existing != null) {
      existing.updateNode(node);
      return existing.channel as TelemetryChannel<T>;
    }

    final entry = _TelemetryEntry<T>(node);
    _entries[nodeId] = entry;
    return entry.channel;
  }

  /// Reconciles active channels after a [GraphDiff] is applied: closes channels
  /// for removed `nodeId`s and rebinds surviving channels to the new [AudioNode]
  /// instances in [diff.snapshot].
  void onGraphDiff(GraphDiff diff) {
    for (final id in diff.removedNodeIds) {
      final removed = _entries.remove(id);
      if (removed != null) {
        unawaited(removed.close());
      }
    }

    if (_entries.isEmpty) return;
    for (final MapEntry(key: node, value: id)
        in diff.snapshot.nodeIds.entries) {
      final entry = _entries[id];
      if (entry != null) {
        entry.updateNode(node);
      }
    }
  }

  /// Dispatches a batched telemetry frame from [AudioEngine] to active
  /// channels using zero-copy [Float32List.sublistView] slices.
  void dispatch(Int32List meta, Float32List data, int entryCount) {
    if (_entries.isEmpty || entryCount <= 0) return;
    for (int i = 0; i < entryCount; i++) {
      final base = i * 3;
      final nodeId = meta[base];
      final entry = _entries[nodeId];
      if (entry == null) continue;

      final offset = meta[base + 1];
      final length = meta[base + 2];
      entry.deliver(Float32List.sublistView(data, offset, offset + length));
    }
  }

  /// Closes all active telemetry channels and clears the registry.
  Future<void> dispose() async {
    final entries = _entries.values.toList();
    _entries.clear();
    for (final entry in entries) {
      await entry.close();
    }
  }
}
