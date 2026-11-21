import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hum/hum.dart';

import 'hum_audio_session.dart';

/// Factory signature for opening a [HumAudioSession] (overridable in tests).
typedef HumSessionOpener = Future<HumAudioSession> Function({
  bool enableOutput,
  bool enableInput,
  int? sampleRate,
  int? vectorSize,
  int? outputChannels,
  int? inputChannels,
  int bufferFrames,
  String? outputDeviceId,
  String? inputDeviceId,
});

/// A Flutter [ChangeNotifier] that manages a [HumAudioSession] and hooks into
/// [AppLifecycleListener] to stop audio cleanly on background/detach and
/// dispose resources on teardown.
class HumAudioController({
  /// Whether playback is automatically stopped when the app pauses or detaches.
  final bool pauseOnBackground = true,

  HumSessionOpener? sessionOpener,
}) extends ChangeNotifier {
  final HumSessionOpener _openSession = sessionOpener ?? HumAudioSession.open;
  AppLifecycleListener? _lifecycleListener;
  HumAudioSession? _session;
  StreamSubscription<AudioPlaybackError>? _errorSub;
  bool _isStarting = false;
  bool _isDisposed = false;
  Object? _lastError;

  this {
    if (pauseOnBackground) {
      _lifecycleListener = AppLifecycleListener(
        onPause: _handleBackground,
        onDetach: _handleBackground,
      );
    }
  }

  /// The currently active [HumAudioSession], if started.
  HumAudioSession? get session => _session;

  /// Whether a session is currently starting.
  bool get isStarting => _isStarting;

  /// Whether audio playback/capture is currently active.
  bool get isPlaying => _session?.isPlaying ?? false;

  /// The most recent startup or runtime playback error, if any.
  Object? get lastError => _lastError;

  /// Opens a new [HumAudioSession], builds and installs the graph returned by
  /// [buildGraph], and starts playback/capture.
  ///
  /// Any previously active session is stopped and disposed first.
  Future<void> start({
    required AudioNode Function(HumAudioSession session) buildGraph,
    bool enableOutput = true,
    bool enableInput = false,
    int? sampleRate,
    int? vectorSize,
    int? outputChannels,
    int? inputChannels,
    int bufferFrames = 2048,
    String? outputDeviceId,
    String? inputDeviceId,
  }) async {
    if (_isDisposed) {
      throw StateError('HumAudioController has been disposed.');
    }

    if (_session != null) {
      await stop();
    }

    _isStarting = true;
    _lastError = null;
    notifyListeners();

    // Call `_openSession` synchronously before any microtask yield when idle
    // so Web Audio's `AudioContext` is created inside the user gesture.
    HumAudioSession? created;
    try {
      created = await _openSession(
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

      if (_isDisposed) {
        await created.dispose();
        return;
      }

      final root = buildGraph(created);
      final diagnostics = created.setGraph(root: root);
      if (diagnostics.isNotEmpty) {
        throw StateError('Graph validation failed: $diagnostics');
      }

      _errorSub = created.playbackErrors.listen((err) {
        _lastError = err.error;
        if (!_isDisposed) notifyListeners();
      });

      await created.start();

      if (_isDisposed) {
        await _errorSub?.cancel();
        _errorSub = null;
        await created.dispose();
        return;
      }

      _session = created;
      created = null;
    } catch (e) {
      _lastError = e;
      await _errorSub?.cancel();
      _errorSub = null;
      await created?.dispose();
      rethrow;
    } finally {
      _isStarting = false;
      if (!_isDisposed) notifyListeners();
    }
  }

  /// Stops and disposes the active session, if any.
  Future<void> stop() async {
    final active = _session;
    final sub = _errorSub;
    _session = null;
    _errorSub = null;

    await sub?.cancel();
    if (active != null) {
      await active.dispose();
    }

    if (!_isDisposed) notifyListeners();
  }

  /// Compiles, validates, and swaps the active audio graph in place.
  ///
  /// Returns an empty list when no session is currently active.
  List<NodeDiagnostic> setGraph({
    AudioNode? root,
    List<AudioNode>? roots,
    List<Outlet>? targetOutputs,
  }) {
    final active = _session;
    if (active == null || active.isDisposed) return const [];
    return active.setGraph(
      root: root,
      roots: roots,
      targetOutputs: targetOutputs,
    );
  }

  /// Forwards a fast-path parameter update to the active session.
  void update(AudioNode node, Object params) {
    _session?.update(node, params);
  }

  /// Returns a typed [TelemetryChannel] for [node] on the active session, or
  /// `null` if stopped or [node] is not in the compiled graph.
  TelemetryChannel<T>? telemetryOf<T>(TelemetryNode<T> node) =>
      _session?.telemetryOf<T>(node);

  void _handleBackground() {
    if (!_isDisposed && (_session != null || _isStarting)) {
      unawaited(stop());
    }
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;

    final active = _session;
    final sub = _errorSub;
    _session = null;
    _errorSub = null;

    if (sub != null) {
      unawaited(sub.cancel());
    }

    if (active != null) {
      unawaited(active.dispose());
    }

    super.dispose();
  }
}
