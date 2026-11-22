# hum_flutter

Cross-platform Flutter integration for the [`hum`](https://github.com/alexobviously/hum) audio DSP engine across **macOS, Linux, Windows, iOS, and Web (Wasm/JS)**.


`hum_flutter` automatically selects the right host and audio I/O backend per platform via conditional imports:

- **Desktop & iOS:** `IsolateAudioHost` + `hum_cpal` (Rust CPAL over Dart FFI)
- **Web:** `AudioHost.sync` + `hum_web` (`AudioWorklet`, Wasm-ready, no `SharedArrayBuffer` / COOP+COEP headers required)

ANDROID IS COMING SOON! I just need to spend a bit of time figuring out the ndk context thing.  

For desktop, I've only tested macos so far. In theory it works on linux and windows but lmk if it doesn't (make an issue on gh).

## Quick Start

### Using `HumAudioController` (recommended for widgets)

`HumAudioController` is a `ChangeNotifier` that manages opening/closing a `HumAudioSession` and automatically pauses playback when the app backgrounds or detaches via `AppLifecycleListener`.

```dart
import 'package:hum/hum.dart';
import 'package:hum_flutter/hum_flutter.dart';

final controller = HumAudioController();

// Call inside a button press so Web Audio unlocks within a user gesture.
await controller.start(
  buildGraph: (session) {
    final osc = SineOscillator(frequency: const .value(440));
    final gain = Mult.mono(input: osc.outlet, value: const .value(0.2));
    return Out.stereo(left: gain.outlet, right: gain.outlet);
  },
);

// Stop & clean up when done (or in State.dispose()).
await controller.stop();
controller.dispose();
```

### Using `HumAudioSession` directly

If you manage lifecycle yourself (e.g. Riverpod, Bloc, or background audio), use `HumAudioSession` directly:

```dart
final session = await HumAudioSession.open(
  enableOutput: true,
  enableInput: false,
);

final osc = SineOscillator(frequency: const .value(220));
session.setGraph(root: Out.stereo(left: osc.outlet, right: osc.outlet));
await session.start();

// Fast-path live parameter updates:
session.update(osc, (frequency: 330.0));

await session.dispose();
```

## Requirements

- **Native builds (macOS, Linux, Windows, iOS):** require [`rustup`](https://rustup.rs/) so `hum_cpal`'s Dart Native Assets hook can automatically install its toolchain/targets and compile the Rust audio bridge (plus `libasound2-dev` and `pkg-config` on Linux).
- **Web-only builds:** no Rust toolchain required.

Note: I am looking into a way to distribute prebuilt dylibs for `hum_cpal` so that users don't have to install Rust / build from source. Should be coming fairly soon but lmk if you need it.  

## Platform Setup

### macOS
- **Playback only:** works out of the box.
- **Audio input / microphone:**
  1. Add `<key>com.apple.security.device.audio-input</key><true/>` to `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`.
  2. Add `NSMicrophoneUsageDescription` to `macos/Runner/Info.plist`.

### iOS
- **Playback only:** works out of the box (uses iOS's default `soloAmbient` session).
- **Playing with the mute switch on, background audio, or microphone input:**
  1. For microphone input, add `NSMicrophoneUsageDescription` to `ios/Runner/Info.plist`.
  2. Configure iOS's process-wide `AVAudioSession` (e.g. via [`audio_session`](https://pub.dev/packages/audio_session)) before calling `start()` — `hum_cpal` automatically inherits the active session:
     - `.playback` to play when the hardware mute switch is on or in the background.
     - `.playAndRecord` for full-duplex microphone capture.

### Web
- **User gesture:** call `HumAudioSession.open()` / `HumAudioController.start()` directly from a tap/click handler so the browser creates and unlocks the `AudioContext` inside the user gesture (required by Safari and Chrome).
- **Wasm:** supports `flutter run -d chrome --wasm` and `flutter build web --wasm`.
- **Strict CSP:** `hum_web` loads its `AudioWorklet` from an in-memory `blob:` URL by default. If your site blocks `blob:` workers, use `hum_web` directly with `workletModuleUrl`.

## Example

See [example/](example/) for a cross-platform step sequencer. 
[Also deployed here](https://hum-demo.alxbkr.xyz/)
