import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_cpal/hum_cpal.dart';

import '../hum_audio_session.dart';

/// Native (Desktop & iOS) implementation backed by `IsolateAudioHost` and
/// `hum_cpal`.
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
  final snapshot = CpalHostSnapshot.probe();

  final outDevice = enableOutput
      ? _resolveDevice(snapshot, outputDeviceId, isOutput: true)
      : null;
  final inDevice = enableInput
      ? _resolveDevice(snapshot, inputDeviceId, isOutput: false)
      : null;

  final outCfg = outDevice?.defaultOutput;
  final inCfg = inDevice?.defaultInput;

  if (enableOutput && outCfg == null && sampleRate == null) {
    throw StateError('No usable native audio output device available.');
  }
  if (enableInput && inCfg == null && sampleRate == null) {
    throw StateError('No usable native audio input device available.');
  }

  final resolvedSampleRate =
      sampleRate ?? outCfg?.sampleRate ?? inCfg?.sampleRate ?? 48000;
  final resolvedVectorSize = vectorSize ?? 64;
  final resolvedOutChannels = enableOutput
      ? (outputChannels ?? outCfg?.channels ?? 2)
      : 0;
  final resolvedInChannels = enableInput
      ? (inputChannels ?? inCfg?.channels ?? 1)
      : 0;

  if (enableOutput &&
      enableInput &&
      sampleRate == null &&
      outCfg != null &&
      inCfg != null &&
      outCfg.sampleRate != inCfg.sampleRate) {
    throw StateError(
      'Default input sample rate (${inCfg.sampleRate} Hz) does not match '
      'default output sample rate (${outCfg.sampleRate} Hz). Pass an explicit '
      'sampleRate or select devices with matching sample rates.',
    );
  }

  final context = ProcessContext(
    sampleRate: resolvedSampleRate,
    vectorSize: resolvedVectorSize,
  );

  final host = await IsolateAudioHost.spawn(context: context);

  final output = enableOutput
      ? CpalAudioOutput(
          numChannels: resolvedOutChannels,
          vectorSize: resolvedVectorSize,
          deviceId: outputDeviceId,
          bufferFrames: bufferFrames,
        )
      : null;

  final input = enableInput
      ? CpalAudioInput(
          numChannels: resolvedInChannels,
          vectorSize: resolvedVectorSize,
          deviceId: inputDeviceId,
          bufferFrames: bufferFrames,
        )
      : null;

  return HumAudioSession(
    host: host,
    output: output,
    input: input,
    outputChannels: resolvedOutChannels,
    inputChannels: resolvedInChannels,
  );
}

CpalDeviceInfo? _resolveDevice(
  CpalHostSnapshot snapshot,
  String? deviceId, {
  required bool isOutput,
}) {
  if (deviceId != null) {
    for (final device in snapshot.devices) {
      if (device.id == deviceId) return device;
    }
    return null;
  }
  return isOutput ? snapshot.defaultOutputDevice : snapshot.defaultInputDevice;
}
