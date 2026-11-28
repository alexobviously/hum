// Native-only helpers that rely on `dart:io` and `dart:ffi`.
// Do not import this library on Web — use `package:hum_codecs/hum_codecs.dart`.

export 'hum_codecs.dart';
export 'src/decode_native.dart' show decodeAudioSync, loadAudio, loadAudioSync;
