import '../hum_audio_session.dart';

/// Fallback stub for unsupported platforms.
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
}) {
  throw UnsupportedError(
    'HumAudioSession is not supported on this platform.',
  );
}
