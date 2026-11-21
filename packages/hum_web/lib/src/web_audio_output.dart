import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:web/web.dart' as web;

import 'web_playback_pacer.dart';
import 'worklet_source.dart';

/// Immutable configuration descriptor for an [AudioOutput] that streams audio
/// to the browser's Web Audio API via an `AudioWorkletProcessor`.
///
/// If [audioContext] is omitted, [WebAudioOutputDriver.start] creates an
/// [web.AudioContext] configured with the host's [ProcessContext.sampleRate]
/// and closes it on [WebAudioOutputDriver.close]. Pass an existing
/// [web.AudioContext] (or [web.OfflineAudioContext] for headless tests) to share
/// lifecycle management with the application.
///
/// If [workletModuleUrl] is omitted, the embedded `AudioWorkletProcessor` script
/// is loaded via a temporary `Blob` URL. Provide an explicit URL if your app's
/// Content Security Policy disallows `blob:` worklet modules.
class const WebAudioOutput({
  @override required final int numChannels,
  @override final int vectorSize = 128,
  final int bufferFrames = 2048,
  final web.BaseAudioContext? audioContext,

  /// Optional URL to a hosted copy of the `AudioWorkletProcessor` script.
  ///
  /// When `null` (default), the embedded worklet script is loaded from an
  /// in-memory `blob:` URL. Provide a hosted script URL if your site sends a
  /// strict Content Security Policy (CSP) header that blocks `blob:` scripts
  /// (e.g. `script-src` / `worker-src` without `blob:`).
  final String? workletModuleUrl,
}) extends AudioOutput {
  this
    : assert(numChannels > 0, 'numChannels must be positive'),
      assert(vectorSize > 0, 'vectorSize must be positive'),
      assert(
        bufferFrames >= vectorSize,
        'bufferFrames must be at least vectorSize',
      );

  @override
  bool get isIsolateSendable => false;

  @override
  AudioOutputDriver createDriver() => WebAudioOutputDriver(
    numChannels: numChannels,
    vectorSize: vectorSize,
    bufferFrames: bufferFrames,
    audioContext: audioContext,
    workletModuleUrl: workletModuleUrl,
  );
}

/// Runtime driver created by [WebAudioOutput.createDriver].
///
/// Loads the ring-buffer `AudioWorkletProcessor`, streams interleaved `Float32`
/// blocks over `MessagePort`, and drives event-based backpressure via
/// [WebPlaybackPacer].
class WebAudioOutputDriver({
  @override required final int numChannels,
  // Web audio typically uses 128 for vector size.
  @override final int vectorSize = 128,
  final int bufferFrames = 2048,
  final web.BaseAudioContext? audioContext,

  /// Optional URL to a hosted copy of the `AudioWorkletProcessor` script.
  ///
  /// When `null` (default), the embedded worklet script is loaded from an
  /// in-memory `blob:` URL. Provide a hosted script URL if your site sends a
  /// strict Content Security Policy (CSP) header that blocks `blob:` scripts
  /// (e.g. `script-src` / `worker-src` without `blob:`).
  final String? workletModuleUrl,
}) extends AudioOutputDriver {
  web.BaseAudioContext? _context;
  bool _ownsContext = false;
  web.AudioWorkletNode? _workletNode;
  WebPlaybackPacer? _pacer;
  Float32List? _scratch;
  int _underruns = 0;
  bool _isClosed = false;

  /// Whether the `AudioWorkletNode` is currently active.
  bool get isOpen => _workletNode != null && !_isClosed;

  /// Whether [close] has been called on this driver.
  bool get isClosed => _isClosed;

  /// The active [web.BaseAudioContext], if started.
  web.BaseAudioContext? get context => _context;

  /// Actual sample rate reported by the active [web.BaseAudioContext], or `null`
  /// if not started.
  int? get sampleRate => _context?.sampleRate.round();

  /// Total audio-thread underruns reported by the `AudioWorkletProcessor`.
  int get underruns => _underruns;

  @override
  Future<void> start(ProcessContext context) async {
    if (_isClosed) {
      throw StateError('WebAudioOutputDriver has been closed.');
    }
    if (_workletNode != null) return;

    if (context.vectorSize != vectorSize) {
      throw ArgumentError.value(
        context.vectorSize,
        'context.vectorSize',
        'Expected vectorSize $vectorSize',
      );
    }
    if (bufferFrames < vectorSize) {
      throw ArgumentError.value(
        bufferFrames,
        'bufferFrames',
        'Must be at least vectorSize ($vectorSize)',
      );
    }

    // Reuse a caller-supplied context (including OfflineAudioContext in tests),
    // or create and own a live AudioContext matching the engine's sample rate.
    final web.BaseAudioContext ctx;
    if (audioContext != null) {
      ctx = audioContext!;
      _ownsContext = false;
    } else {
      ctx = web.AudioContext(
        web.AudioContextOptions(sampleRate: context.sampleRate.toDouble()),
      );
      _ownsContext = true;
    }
    _context = ctx;

    String? createdBlobUrl;
    try {
      // Load the worklet JS either from a hosted URL or an in-memory Blob URL.
      final String moduleUrl;
      if (workletModuleUrl != null) {
        moduleUrl = workletModuleUrl!;
      } else {
        final blob = web.Blob(
          <JSAny>[humWorkletJsSource.toJS].toJS,
          web.BlobPropertyBag(type: 'application/javascript'),
        );
        createdBlobUrl = web.URL.createObjectURL(blob);
        moduleUrl = createdBlobUrl;
      }

      await ctx.audioWorklet.addModule(moduleUrl).toDart;

      // Instantiate the worklet node with the ring buffer dimensions; the
      // ring buffer itself lives inside the AudioWorklet on the audio thread.
      final processorOptions = JSObject()
        ..['numChannels'] = numChannels.toJS
        ..['bufferFrames'] = bufferFrames.toJS;

      final nodeOptions = web.AudioWorkletNodeOptions(
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: <JSNumber>[numChannels.toJS].toJS,
        processorOptions: processorOptions,
      );

      final node = web.AudioWorkletNode(
        ctx,
        humWorkletProcessorName,
        nodeOptions,
      );

      // Receive drained-frame credits and underrun counts from the worklet.
      node.port.onmessage = (web.MessageEvent event) {
        _handleWorkletMessage(event.data);
      }.toJS;

      node.connect(ctx.destination);
      _workletNode = node;
      _scratch = Float32List(numChannels * vectorSize);

      // Live AudioContexts start suspended until unlocked by a user gesture
      // (OfflineAudioContext is a BaseAudioContext and does not use resume()).
      if (ctx.isA<web.AudioContext>() && ctx.state == 'suspended') {
        await (ctx as web.AudioContext).resume().toDart;
      }
    } catch (_) {
      await _cleanupResources();
      rethrow;
    } finally {
      // Safe to revoke once addModule() has finished loading the script.
      if (createdBlobUrl != null) {
        web.URL.revokeObjectURL(createdBlobUrl);
      }
    }
  }

  // Handles backpressure credit messages posted by the worklet's process()
  // callback after it drains frames from its ring buffer.
  void _handleWorkletMessage(JSAny? raw) {
    if (_isClosed || raw == null || !raw.isA<JSObject>()) return;
    final msg = raw as JSObject;
    final type = msg['type'];
    if (type != null &&
        type.isA<JSString>() &&
        (type as JSString).toDart == 'consumed') {
      final framesVal = msg['frames'];
      if (framesVal != null && framesVal.isA<JSNumber>()) {
        final consumed = (framesVal as JSNumber).toDartInt;
        _pacer?.onFramesConsumed(consumed);
      }
      final underrunsVal = msg['underruns'];
      if (underrunsVal != null && underrunsVal.isA<JSNumber>()) {
        _underruns = (underrunsVal as JSNumber).toDartInt;
      }
    }
  }

  @override
  PlaybackPacer createPacer(ProcessContext context) {
    if (_workletNode == null) {
      throw StateError(
        'Cannot create a pacer before WebAudioOutputDriver.start().',
      );
    }
    return _pacer = WebPlaybackPacer(
      vectorSize: vectorSize,
      bufferFrames: bufferFrames,
      isStopped: () => _isClosed || _workletNode == null,
    );
  }

  @override
  void write(List<Float32List> channels) {
    final node = _workletNode;
    final scratch = _scratch;
    if (_isClosed || node == null || scratch == null) return;

    interleaveFloats(channels, scratch, vectorSize: vectorSize);

    // Send a structured-cloned Float32Array (no transfer list) so `_scratch`
    // stays reusable across both dart2wasm and dart2js.
    final msg = JSObject()
      ..['type'] = 'audio'.toJS
      ..['data'] = scratch.toJS
      ..['frames'] = vectorSize.toJS;

    node.port.postMessage(msg);
  }

  Future<void> _cleanupResources() async {
    final node = _workletNode;
    final ctx = _context;
    final ownsCtx = _ownsContext;
    _workletNode = null;
    _context = null;
    _ownsContext = false;
    _scratch = null;
    _pacer?.stop();
    _pacer = null;

    if (node != null) {
      try {
        // Tell the worklet to return `false` from process() so it can be GC'd.
        final stopMsg = JSObject()..['type'] = 'stop'.toJS;
        node.port.postMessage(stopMsg);
        node.port.onmessage = null;
        node.port.close();
        node.disconnect();
      } catch (_) {}
    }

    // Only close the AudioContext if this driver created it.
    if (ownsCtx && ctx != null && ctx.isA<web.AudioContext>()) {
      try {
        await (ctx as web.AudioContext).close().toDart;
      } catch (_) {}
    }
  }

  @override
  Future<void> close({bool waitForExit = true}) async {
    if (_isClosed) return;
    _isClosed = true;
    await _cleanupResources();
  }
}
