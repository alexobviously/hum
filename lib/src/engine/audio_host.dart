import 'dart:typed_data';

import 'package:hum/hum.dart';

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

  /// Starts continuous real-time audio playback streaming graph outputs to [output].
  ///
  /// Paced to real-time deadlines with backpressure to prevent buffer bloat.
  ///
  /// Throws [StateError] if playback is already active or if no graph is loaded.
  /// Throws [ArgumentError] if [output] channel count or vector size does not match
  /// the active graph context.
  Future<void> startPlayback(AudioOutput output);

  /// Stops continuous real-time audio playback.
  Future<void> stopPlayback();

  /// Disposes resources and terminates the background isolate worker if active.
  Future<void> dispose();

  /// Spawns an [AudioHost] running inside a dedicated background worker isolate.
  ///
  /// This is the recommended mode for UI applications (Flutter, desktop) to ensure
  /// real-time audio computation never blocks the main thread.
  static Future<AudioHost> spawn({required ProcessContext context}) =>
      IsolateAudioHost.spawn(context: context);

  /// Creates a synchronous [AudioHost] running directly on the caller thread.
  ///
  /// Ideal for unit testing, offline batch scripts, and WebAssembly / Flutter Web.
  factory sync({required ProcessContext context}) = SyncAudioHost;
}
