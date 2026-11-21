import 'dart:js_interop';

import 'package:hum/hum.dart';
import 'package:hum_web/hum_web.dart';
import 'package:web/web.dart' as web;

import '../hum_audio_session.dart';

/// Web implementation backed by `AudioHost.sync` and `hum_web` (`AudioWorklet`).
///
/// Creates the `web.AudioContext` synchronously before any `await` so browsers
/// (especially Safari) unlock audio when called inside a user gesture.
Future<HumAudioSession> openPlatformSession({
  required bool enableOutput,
  required bool enableInput,
  int? sampleRate,
  int? vectorSize,
  int? outputChannels,
  int? inputChannels,
  int bufferFrames = 2048,
  String? outputDeviceId,
  String? inputDeviceId,
}) async {
  // Create AudioContext synchronously before any `await` (Safari autoplay).
  final audioCtx = sampleRate != null
      ? web.AudioContext(
          web.AudioContextOptions(sampleRate: sampleRate.toDouble()),
        )
      : web.AudioContext();

  final resolvedSampleRate = audioCtx.sampleRate.round();
  final resolvedVectorSize = vectorSize ?? 128;
  final resolvedOutChannels = enableOutput ? (outputChannels ?? 2) : 0;
  final resolvedInChannels = enableInput ? (inputChannels ?? 1) : 0;

  final context = ProcessContext(
    sampleRate: resolvedSampleRate,
    vectorSize: resolvedVectorSize,
  );

  final host = AudioHost.sync(context: context);

  final output = enableOutput
      ? WebAudioOutput(
          numChannels: resolvedOutChannels,
          vectorSize: resolvedVectorSize,
          bufferFrames: bufferFrames,
          audioContext: audioCtx,
        )
      : null;

  final input = enableInput
      ? WebAudioInput(
          numChannels: resolvedInChannels,
          vectorSize: resolvedVectorSize,
          bufferFrames: bufferFrames,
          audioContext: audioCtx,
          deviceId: inputDeviceId,
        )
      : null;

  return HumAudioSession(
    host: host,
    output: output,
    input: input,
    outputChannels: resolvedOutChannels,
    inputChannels: resolvedInChannels,
    onDispose: () async {
      try {
        await audioCtx.close().toDart;
      } catch (_) {}
    },
  );
}
