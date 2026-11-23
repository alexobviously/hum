# hum_cpal

Native hardware audio I/O bridge for [`hum`](https://pub.dev/packages/hum), backed by Rust [`cpal`](https://github.com/RustAudio/cpal) and lock-free `rtrb` ring buffers over Dart FFI / Native Assets.

Supports **macOS, Linux, Windows, Android and iOS**.

This package is agnostic of Flutter. If you want a quick and easy way to integrate Hum into your Flutter project, take a look at [`hum_flutter`](https://pub.dev/packages/hum_flutter).

## Note about Bluetooth

Bluetooth A2DP requires a larger `bufferFrames` param, because the burst size can be quite high. I'm planning to add some more intelligent support for this in the near future (decoupling buffer size from burst size, etc).

## Features

- **`CpalAudioOutput`** — real-time hardware playback (`isIsolateSendable: true`, works on `IsolateAudioHost`).
- **`CpalAudioInput`** — live hardware microphone/interface capture (`f32` preferred with automatic `i32`/`i16`/`u16` → `f32` conversion).
- **`CpalHostSnapshot.probe()`** — enumerate host audio devices, default input/output, supported sample rates, channel counts, and buffer ranges.
- **`hardwareBufferFrames`** — optional fixed OS hardware period (`BufferSize::Fixed(n)`) for low-latency monitoring/pedalboards.

## Usage

```dart
import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_cpal/hum_cpal.dart';

final snapshot = CpalHostSnapshot.probe();
final config = snapshot.defaultOutputDevice!.defaultOutput!;

final context = ProcessContext(sampleRate: config.sampleRate, vectorSize: 64);
final host = await IsolateAudioHost.spawn(context: context);

final osc = SineOscillator(frequency: const .value(440));
final gain = Mult.mono(input: osc.outlet, value: const .value(0.2));
host.setGraph(root: Out.stereo(left: gain.outlet, right: gain.outlet));

await host.startPlayback(
  output: CpalAudioOutput(
    numChannels: config.channels,
    vectorSize: 64,
    bufferFrames: 2048,
  ),
);
```

See [example/main.dart](example/main.dart) (synth playback) and [example/mic_fx_demo.dart](example/mic_fx_demo.dart) (live input + output FX) for complete examples.

## Requirements

`hum_cpal` compiles its Rust bridge automatically via Dart Native Assets (`hook/build.dart`). Building from source requires the Rust toolchain (`rustup` / `cargo`), and on Linux `libasound2-dev` + `pkg-config` for ALSA.
