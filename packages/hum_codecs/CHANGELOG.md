## 0.1.0

- Initial release of `hum_codecs`.
- Native audio decoding powered by Rust `symphonia` over Dart FFI (MP3, FLAC, Ogg Vorbis, AAC/M4A, ALAC, WAV, AIFF).
- Browser audio decoding powered by Web Audio `AudioContext.decodeAudioData`.
- Cross-platform async `decodeAudio(Uint8List)` entrypoint (`hum_codecs.dart`) and native-only `decodeAudioSync`, `loadAudio`, `loadAudioSync` helpers (`native.dart`).
