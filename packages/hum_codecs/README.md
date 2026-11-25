# hum_codecs

Cross-platform compressed audio decoding for [`hum`](https://pub.dev/packages/hum) into planar 32-bit float `AudioBuffer`s.

- **Native (macOS, iOS, Android, Linux, Windows):** Powered by the pure-Rust [**Symphonia**](https://github.com/pdeljanov/Symphonia) multimedia library (licensed under [MPL-2.0](https://github.com/pdeljanov/Symphonia/blob/master/LICENSE)) over Dart FFI / Native Assets (zero C/FFmpeg runtime dependencies). Huge thanks to the Symphonia authors and contributors!
- **Web / Wasm:** Powered by the browser's built-in Web Audio `AudioContext.decodeAudioData` API (zero Wasm bundle bloat).

> **Note on encoding:** `hum_codecs` currently focuses on **decoding**. Compressed encoders (e.g. FLAC / MP3 / Ogg export) are planned for a future release. Uncompressed 16-bit PCM and 32-bit float WAV writing is already built into `package:hum` (`writeWav` / `exportWav`).

## Format Support (Decoding)

| Format | Extensions | Native ([Symphonia](https://github.com/pdeljanov/Symphonia)) | Web (Browser `decodeAudioData`) |
| :--- | :--- | :---: | :---: |
| **MP3** | `.mp3` | Yes | Yes |
| **FLAC** | `.flac` | Yes | Yes |
| **Ogg Vorbis** | `.ogg`, `.oga` | Yes | Chrome / Firefox (limited on Safari) |
| **AAC / MP4** | `.m4a`, `.aac`, `.mp4` | Yes | Yes |
| **ALAC** | `.m4a`, `.caf` | Yes | Safari (varies by browser) |
| **WAV (PCM / Float)** | `.wav` | Yes | Yes |
| **AIFF** | `.aif`, `.aiff` | Yes | Safari (varies by browser) |
| **Opus** | `.opus`, `.webm`, `.ogg` | Planned | Yes (modern browsers) |

## Usage

### Cross-platform (Desktop, Mobile, and Web)

`package:hum_codecs/hum_codecs.dart` exposes an async `decodeAudio` function that runs off the UI thread (`Isolate.run`) on native and calls `AudioContext.decodeAudioData` on Web:

```dart
import 'dart:typed_data';
import 'package:hum/hum.dart';
import 'package:hum_codecs/hum_codecs.dart';

Future<void> playSample(AudioHost host, Uint8List mp3Bytes) async {
  final buffer = await decodeAudio(mp3Bytes, hint: 'mp3');
  final handle = host.loadBuffer(buffer);

  final player = SamplePlayer(buffer: handle, loop: true);
  host.setGraph(root: Out.stereo(left: player.left, right: player.right));
}
```

### Native-only helpers (`dart:io` + synchronous FFI)

For CLI scripts, tests, or loading directly from file paths on native platforms, import `package:hum_codecs/native.dart`:

```dart
import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_codecs/native.dart';

Future<void> main() async {
  // Async file load + off-thread decode (auto-detects extension hint):
  final buffer = await loadAudio('assets/breakbeat.flac');

  // Or synchronous decode for CLI tools / tests:
  final oneShot = loadAudioSync('assets/kick.mp3');
}
```

## Requirements (Native)

Building native targets requires a Rust toolchain (`rustup`); `packages/hum_codecs/hook/build.dart` compiles the Rust crate automatically via Dart Native Assets (and skips `cargo` on Web builds).
