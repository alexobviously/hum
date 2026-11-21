import 'package:hum/hum.dart';

import 'platform/backend.dart';

/// A platform-adaptive audio session uniting an [AudioHost] with its
/// platform-specific [AudioOutput] and/or [AudioInput] descriptors.
///
/// On native platforms (macOS, Linux, Windows, iOS), [HumAudioSession.open]
/// spawns an `IsolateAudioHost` backed by `hum_cpal`.
///
/// On Web, [HumAudioSession.open] creates a `web.AudioContext` synchronously
/// inside the caller's user gesture (before any `await`) and pairs an
/// `AudioHost.sync` with `hum_web` (`AudioWorklet`), sharing a single
/// `AudioContext` for full-duplex sessions.
class HumAudioSession {
  /// Creates a session wrapping an already-initialized [host] and optional
  /// [output] / [input] descriptors.
  HumAudioSession({
    required this.host,
    this.output,
    this.input,
    this.outputChannels = 0,
    this.inputChannels = 0,
    Future<void> Function()? onDispose,
  }) : _onDisposeCallback = onDispose;

  /// The underlying [AudioHost] (`IsolateAudioHost` on native, `SyncAudioHost`
  /// on Web).
  final AudioHost host;

  /// Output descriptor configured for this session, if output is enabled.
  final AudioOutput? output;

  /// Input descriptor configured for this session, if input is enabled.
  final AudioInput? input;

  /// Number of output channels configured (0 when output is disabled).
  final int outputChannels;

  /// Number of input channels configured (0 when input is disabled).
  final int inputChannels;

  final Future<void> Function()? _onDisposeCallback;
  bool _isDisposed = false;

  /// Opens a platform-appropriate [HumAudioSession].
  ///
  /// When [sampleRate], [outputChannels], or [inputChannels] are omitted,
  /// sensible defaults are probed from the active audio device (native) or
  /// browser `AudioContext` (Web).
  ///
  /// On Web, call this directly inside a button tap/click handler so the
  /// underlying `AudioContext` is created within a user gesture.
  static Future<HumAudioSession> open({
    bool enableOutput = true,
    bool enableInput = false,
    int? sampleRate,
    int? vectorSize,
    int? outputChannels,
    int? inputChannels,
    int bufferFrames = 2048,
    String? outputDeviceId,
    String? inputDeviceId,
  }) => openPlatformSession(
    enableOutput: enableOutput,
    enableInput: enableInput,
    sampleRate: sampleRate,
    vectorSize: vectorSize,
    outputChannels: outputChannels,
    inputChannels: inputChannels,
    bufferFrames: bufferFrames,
    outputDeviceId: outputDeviceId,
    inputDeviceId: inputDeviceId,
  );

  /// The active [ProcessContext] (`sampleRate` and `vectorSize`).
  ProcessContext get context => host.context;

  /// Whether real-time playback/capture is currently running.
  bool get isPlaying => host.isPlaying;

  /// Whether [dispose] has been called on this session.
  bool get isDisposed => _isDisposed;

  /// Broadcast stream of asynchronous runtime errors during playback.
  Stream<AudioPlaybackError> get playbackErrors => host.playbackErrors;

  /// Compiles, validates, and installs the audio graph on [host].
  List<NodeDiagnostic> setGraph({
    AudioNode? root,
    List<AudioNode>? roots,
    List<Outlet>? targetOutputs,
  }) {
    _checkNotDisposed();
    return host.setGraph(
      root: root,
      roots: roots,
      targetOutputs: targetOutputs,
    );
  }

  /// Starts real-time playback and/or capture using the session's configured
  /// [output] and [input].
  Future<void> start() {
    _checkNotDisposed();
    return host.startPlayback(output: output, input: input);
  }

  /// Stops real-time playback and/or capture without disposing the session.
  Future<void> stop() {
    if (_isDisposed) return Future<void>.value();
    return host.stopPlayback();
  }

  /// Fast-path in-place parameter update for [node].
  void update(AudioNode node, Object params) {
    if (_isDisposed) return;
    host.update(node, params);
  }

  /// Fast-path in-place parameter update by integer [nodeId].
  void updateById(int nodeId, Object params) {
    if (_isDisposed) return;
    host.updateById(nodeId, params);
  }

  /// Stops playback, disposes [host], and releases any platform-owned
  /// resources (such as a Web `AudioContext`). Safe to call multiple times.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    try {
      if (host.isPlaying) {
        await host.stopPlayback();
      }
    } finally {
      await host.dispose();
      await _onDisposeCallback?.call();
    }
  }

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw StateError('HumAudioSession has been disposed.');
    }
  }
}
