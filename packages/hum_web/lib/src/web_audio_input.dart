import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:hum/hum.dart';
import 'package:web/web.dart' as web;

import 'input_ring_buffer.dart';
import 'web_input_playback_pacer.dart';
import 'worklet_source.dart';

/// Immutable configuration descriptor for an [AudioInput] that captures live
/// multi-channel audio from the browser's Web Audio API via an
/// `AudioWorkletProcessor`.
///
/// Pass the same [web.AudioContext] to both [WebAudioInput] and
/// `WebAudioOutput` for clock-locked full-duplex operation.
///
/// If [sourceNode] is omitted, [WebAudioInputDriver.start] requests microphone
/// access via `navigator.mediaDevices.getUserMedia` and stops all captured
/// `MediaStream` tracks on [WebAudioInputDriver.close]. Pass an explicit
/// [sourceNode] (such as a `MediaStreamAudioSourceNode` or a test
/// `OscillatorNode` on `OfflineAudioContext`) to bypass `getUserMedia`.
class const WebAudioInput({
  @override required final int numChannels,
  @override final int vectorSize = 128,
  final int bufferFrames = 2048,
  final web.BaseAudioContext? audioContext,
  final web.AudioNode? sourceNode,
  final String? deviceId,
  final bool echoCancellation = false,
  final bool noiseSuppression = false,
  final bool autoGainControl = false,

  /// Optional URL to a hosted copy of the capture `AudioWorkletProcessor`
  /// script.
  ///
  /// When `null` (default), the embedded worklet script is loaded from an
  /// in-memory `blob:` URL. Provide a hosted script URL if your site sends a
  /// strict Content Security Policy (CSP) header that blocks `blob:` scripts
  /// (e.g. `script-src` / `worker-src` without `blob:`).
  final String? workletModuleUrl,
}) extends AudioInput {
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
  AudioInputDriver createDriver() => WebAudioInputDriver(
    numChannels: numChannels,
    vectorSize: vectorSize,
    bufferFrames: bufferFrames,
    audioContext: audioContext,
    sourceNode: sourceNode,
    deviceId: deviceId,
    echoCancellation: echoCancellation,
    noiseSuppression: noiseSuppression,
    autoGainControl: autoGainControl,
    workletModuleUrl: workletModuleUrl,
  );
}

/// Runtime capture driver created by [WebAudioInput.createDriver].
///
/// Captures multi-channel blocks from a browser `AudioWorkletProcessor` into
/// a circular [InputRingBuffer] and de-interleaves them into `hum` channel
/// buffers on [read].
class WebAudioInputDriver({
  @override required final int numChannels,
  @override final int vectorSize = 128,
  final int bufferFrames = 2048,
  final web.BaseAudioContext? audioContext,
  final web.AudioNode? sourceNode,
  final String? deviceId,
  final bool echoCancellation = false,
  final bool noiseSuppression = false,
  final bool autoGainControl = false,

  /// Optional URL to a hosted copy of the capture `AudioWorkletProcessor`
  /// script.
  final String? workletModuleUrl,
}) extends AudioInputDriver {
  web.BaseAudioContext? _context;
  bool _ownsContext = false;
  web.MediaStream? _ownedStream;
  web.AudioNode? _connectedSource;
  bool _ownsSourceNode = false;
  web.AudioWorkletNode? _workletNode;
  InputRingBuffer? _ringBuffer;
  WebInputPlaybackPacer? _pacer;
  Float32List? _scratch;
  bool _isClosed = false;

  /// Whether the capture `AudioWorkletNode` is currently active.
  bool get isOpen => _workletNode != null && !_isClosed;

  /// Whether [close] has been called on this driver.
  bool get isClosed => _isClosed;

  /// The active [web.BaseAudioContext], if started.
  web.BaseAudioContext? get context => _context;

  /// Actual sample rate reported by the active [web.BaseAudioContext].
  int? get sampleRate => _context?.sampleRate.round();

  /// Number of captured frames currently buffered and ready for [read].
  int get availableReadFrames => _ringBuffer?.availableFrames ?? 0;

  /// Number of capture overruns (dropped oldest frames when buffer filled).
  int get overruns => _ringBuffer?.overruns ?? 0;

  /// Number of read underruns (zero-filled blocks when buffer was short).
  int get underruns => _ringBuffer?.underruns ?? 0;

  @override
  Future<void> start(ProcessContext context) async {
    if (_isClosed) {
      throw StateError('WebAudioInputDriver has been closed.');
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
      final web.AudioNode source;
      if (sourceNode != null) {
        source = sourceNode!;
        _ownsSourceNode = false;
      } else {
        // Request raw audio capture from the browser via getUserMedia.
        final audioConstraints = JSObject()
          ..['channelCount'] = numChannels.toJS
          ..['echoCancellation'] = echoCancellation.toJS
          ..['noiseSuppression'] = noiseSuppression.toJS
          ..['autoGainControl'] = autoGainControl.toJS;
        if (deviceId != null) {
          audioConstraints['deviceId'] = (JSObject()
            ..['exact'] = deviceId!.toJS);
        }

        final constraints = web.MediaStreamConstraints(
          audio: audioConstraints,
          video: false.toJS,
        );
        final stream = await web.window.navigator.mediaDevices
            .getUserMedia(constraints)
            .toDart;
        _ownedStream = stream;

        if (!ctx.isA<web.AudioContext>()) {
          throw StateError(
            'getUserMedia capture requires a live AudioContext (not OfflineAudioContext).',
          );
        }
        source = (ctx as web.AudioContext).createMediaStreamSource(stream);
        _ownsSourceNode = true;
      }
      _connectedSource = source;

      final String moduleUrl;
      if (workletModuleUrl != null) {
        moduleUrl = workletModuleUrl!;
      } else {
        final blob = web.Blob(
          <JSAny>[humCaptureWorkletJsSource.toJS].toJS,
          web.BlobPropertyBag(type: 'application/javascript'),
        );
        createdBlobUrl = web.URL.createObjectURL(blob);
        moduleUrl = createdBlobUrl;
      }

      await ctx.audioWorklet.addModule(moduleUrl).toDart;

      final processorOptions = JSObject()..['numChannels'] = numChannels.toJS;

      // Single input bus with explicit multi-channel layout (no silent downmix).
      final nodeOptions = web.AudioWorkletNodeOptions(
        numberOfInputs: 1,
        numberOfOutputs: 0,
        channelCount: numChannels,
        channelCountMode: 'explicit',
        channelInterpretation: 'discrete',
        processorOptions: processorOptions,
      );

      final node = web.AudioWorkletNode(
        ctx,
        humCaptureWorkletProcessorName,
        nodeOptions,
      );

      _ringBuffer = InputRingBuffer(
        numChannels: numChannels,
        capacityFrames: bufferFrames,
      );
      _scratch = Float32List(numChannels * vectorSize);

      node.port.onmessage = (web.MessageEvent event) {
        _handleWorkletMessage(event.data);
      }.toJS;

      // Connect source -> capture worklet only (never to ctx.destination, which
      // would create direct speaker feedback).
      source.connect(node);
      _workletNode = node;

      if (ctx.isA<web.AudioContext>() && ctx.state == 'suspended') {
        await (ctx as web.AudioContext).resume().toDart;
      }
    } catch (_) {
      await _cleanupResources();
      rethrow;
    } finally {
      if (createdBlobUrl != null) {
        web.URL.revokeObjectURL(createdBlobUrl);
      }
    }
  }

  void _handleWorkletMessage(JSAny? raw) {
    final ring = _ringBuffer;
    if (_isClosed || ring == null || raw == null || !raw.isA<JSObject>()) {
      return;
    }
    final msg = raw as JSObject;
    final type = msg['type'];
    if (type != null &&
        type.isA<JSString>() &&
        (type as JSString).toDart == 'audio') {
      final dataVal = msg['data'];
      final framesVal = msg['frames'];
      if (dataVal != null &&
          dataVal.isA<JSFloat32Array>() &&
          framesVal != null &&
          framesVal.isA<JSNumber>()) {
        final samples = (dataVal as JSFloat32Array).toDart;
        final frames = (framesVal as JSNumber).toDartInt;
        ring.pushInterleaved(samples, frames);
        _pacer?.onFramesAvailable();
      }
    }
  }

  @override
  PlaybackPacer createPacer(ProcessContext context) {
    if (_workletNode == null) {
      throw StateError(
        'Cannot create a pacer before WebAudioInputDriver.start().',
      );
    }
    return _pacer = WebInputPlaybackPacer(
      vectorSize: vectorSize,
      availableReadFrames: () => availableReadFrames,
      isStopped: () => _isClosed || _workletNode == null,
    );
  }

  @override
  void read(List<Float32List> channels) {
    final ring = _ringBuffer;
    final scratch = _scratch;
    if (_isClosed || ring == null || scratch == null) {
      for (final ch in channels) {
        ch.fillRange(0, vectorSize, 0.0);
      }
      return;
    }

    ring.popInterleaved(scratch, vectorSize);
    deinterleaveFloats(scratch, channels, vectorSize: vectorSize);
  }

  Future<void> _cleanupResources() async {
    final node = _workletNode;
    final source = _connectedSource;
    final ownsSource = _ownsSourceNode;
    final stream = _ownedStream;
    final ctx = _context;
    final ownsCtx = _ownsContext;

    _workletNode = null;
    _connectedSource = null;
    _ownsSourceNode = false;
    _ownedStream = null;
    _context = null;
    _ownsContext = false;
    _ringBuffer?.clear();
    _ringBuffer = null;
    _scratch = null;
    _pacer?.stop();
    _pacer = null;

    if (source != null && node != null) {
      try {
        source.disconnect(node);
      } catch (_) {}
    }
    if (ownsSource && source != null) {
      try {
        source.disconnect();
      } catch (_) {}
    }
    if (node != null) {
      try {
        final stopMsg = JSObject()..['type'] = 'stop'.toJS;
        node.port.postMessage(stopMsg);
        node.port.onmessage = null;
        node.port.close();
        node.disconnect();
      } catch (_) {}
    }
    if (stream != null) {
      // Stop all MediaStream tracks so the browser releases the microphone.
      for (final track in stream.getTracks().toDart) {
        try {
          track.stop();
        } catch (_) {}
      }
    }
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
