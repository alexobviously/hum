import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Error reported asynchronously during continuous real-time playback.
///
/// Emitted on [AudioHost.playbackErrors] when a runtime failure (such as a
/// driver `write` exception or device disconnection) interrupts an already
/// running playback loop. Startup failures are instead thrown directly by
/// [AudioHost.startPlayback].
class const AudioPlaybackError({
  required final Object error,
  final StackTrace? stackTrace,
}) {
  @override
  String toString() => 'AudioPlaybackError($error)';
}

/// The main controller and coordinator for declarative audio graphs.
///
/// Manages graph compilation, state snapshots, and communicates transactions
/// to an underlying [AudioEngine] either synchronously or over an isolate boundary.
abstract class const AudioHost() {
  /// The audio configuration context (sample rate, vector size).
  ProcessContext get context;

  /// The currently active graph snapshot.
  GraphSnapshot get currentSnapshot;

  /// The number of output channels in the currently active graph.
  int get numChannels => currentSnapshot.outputSlots.length;

  /// Compiles, validates, and sets the active audio graph.
  ///
  /// Diffs the new graph against [currentSnapshot] and applies the resulting
  /// [GraphDiff] to the audio engine.
  ///
  /// Returns a list of [NodeDiagnostic]s if validation fails (empty if successful).
  List<NodeDiagnostic> setGraph({
    AudioNode? root,
    List<AudioNode>? roots,
    List<Outlet>? targetOutputs,
  });

  /// Fast-path in-place parameter update for [node] (bypasses full graph diffing).
  void update(AudioNode node, Object params);

  /// Fast-path in-place parameter update by integer [nodeId].
  void updateById(int nodeId, Object params);

  /// Renders [count] blocks of audio and returns the resulting channel buffers.
  Future<List<Float32List>> renderBlocks(int count);

  /// Whether real-time playback is currently active.
  bool get isPlaying;

  /// Broadcast stream of asynchronous errors occurring during active playback.
  Stream<AudioPlaybackError> get playbackErrors;

  /// Starts continuous real-time audio playback, optionally reading from
  /// [input] and streaming graph outputs to [output].
  ///
  /// Paced to real-time deadlines with backpressure to prevent buffer bloat.
  /// If [output] is omitted, the engine runs continuously in real-time without
  /// writing to physical output devices (driving in-graph sinks, analysis
  /// nodes, or input-only graphs).
  ///
  /// Throws [StateError] if playback is already active or if no graph is loaded.
  /// Throws [ArgumentError] if [output] or [input] channel count or vector size
  /// does not match the active graph context.
  Future<void> startPlayback({AudioOutput? output, AudioInput? input});

  /// Stops continuous real-time audio playback.
  Future<void> stopPlayback();

  /// Disposes resources and terminates the background isolate worker if active.
  Future<void> dispose();

  /// Creates a synchronous [AudioHost] running directly on the caller thread.
  ///
  /// Ideal for unit testing, offline batch scripts, and WebAssembly / Flutter Web.
  factory sync({required ProcessContext context}) = SyncAudioHost;
}
