# Hum

Hum is a signal processing library written in Dart. I built it for a lot of reasons and there are a lot of use cases I had in mind.  

* Generative music/live coding (expressive DSL with interpreter coming soon!)
* Software for physical instruments
* Audio processing in Flutter

Everything is written in Dart, apart from hardware i/o (see below for packages). This library is very much WIP but you can already get some pretty useful stuff out of it.  

For now this readme is pretty light. I'll work on getting some more comprehensive documentation together soon. But for now, take a look at the fairly comprehensive [examples](https://github.com/alexobviously/hum/tree/main/packages/hum/example).  

Play with a small flutter web demo [here](https://hum-demo.alxbkr.xyz) if you want to quickly see what it can do.  

## Packages

* [hum](https://pub.dev/packages/hum) (this package): core library with all the audio processing pipeline stuff and node definitions.
  * `hum/io`: `import 'package:hum/io.dart';` - ffplay/sox process wrappers for audio i/o without needing a separate package (part of hum core, just a separate import).
* [hum_flutter](https://pub.dev/packages/hum_flutter): Flutter bindings to allow using hum in Flutter applications.
* [hum_cpal](https://pub.dev/packages/hum_cpal): lite native i/o wrapper using [cpal](https://crates.io/crates/cpal) with ffi bindings.
* [hum_web](https://pub.dev/packages/hum_web): i/o wrapper for web using AudioWorklet.

`hum_flutter` delegates to `hum_cpal` or `hum_web` depending on platform, so start there if you want to incorporate hum into your Flutter app.  

## Architecture

### Audio graphs

The core concept in hum is the **audio graph**. This is a DAG (directed acyclic graph) of nodes, culminating in a terminal node, usually `Out`. Nodes are connected to each other with inlets and outlets, and can take parameters that can be static (i.e. a constant value) or dynamic (e.g. a signal from another node's outlet).  

An audio graph looks something like this:  
```dart
final sine = SineOscillator(frequency: .value(440));
final amp = Mult.mono(input: sine.outlet, value: .value(0.5));
final out = Out.mono(amp.outlet);
```

The `out` node is what you pass to the audio host when telling it to run the graph. More on that below.  

In the example above, we construct each node one by one and maintain references to all the nodes, but you could equally write the same graph like this:

```dart
final out = Out.mono(
  Mult.mono(
    input: SineOscillator(frequency: .value(440)).outlet,
    value: .value(0.5),
  ).outlet,
);
```

There are also some more concise helpers for building graphs. e.g.:
```dart
final square = SquareOscillator(frequency: .value(440)).outlet.mult(0.5);
final noise = NoiseGenerator.white().outlet.mult(.value(0.2));
final combined = square.outlet + noise.outlet;
```

This sort of thing is still WIP and I'm working on a more sophisticated fluent API, maybe even a DSL.  

If you want to start experimenting with audio graphs, a good place to start is by using the `runDemo()` harness in the example project.  

#### Signal params

Use signal params to modulate a node's parameter at audio rate with the outlet of another node (`.signal(...)` instead of `.value(...)`):

```dart
final saw = SawtoothOscillator(frequency: .value(110));
final lfo = SineOscillator(frequency: .value(0.5)).mapRange(200, 2000);
final filter = SvfFilter(
  input: saw.outlet,
  cutoff: .signal(lfo.outlet),
  resonance: .value(2.0),
);
```

#### Telemetry

Nodes implementing `TelemetryNode<T>` (such as `Meter` and `StepSequencer`) stream throttled data back from the audio engine to the host. Subscribe via `host.telemetryOf(node)` (exposing both a `.stream` and a `.latest` getter for polling):

```dart
final meter = Meter.stereo(left: reverb.left, right: reverb.right);
host.setGraph(root: Out.stereo(left: meter.left, right: meter.right));

final levels = host.telemetryOf(meter)!;
levels.stream.listen((r) => print('Peak: ${r.peakDb.toStringAsFixed(1)} dB'));
```
### AudioNode and AudioProcessor

`AudioNode` is the host-side representation of a node in the graph. They have references to other nodes, and use high level types to represent their configurations. Each `AudioNode` class has a matching `AudioProcessor` class, which is instantiated on the engine side in place of the node. Unlike nodes, processors only deal with primitive types and know nothing about any other processors. All they know is their configuration, and how to run `process()` on a block of audio, which is presented as a set of input and output buffers (`Float32List`s).  

I'll write some more stuff later but if you want to know more about how to write your own nodes, for now just take a look at the existing ones. Be careful to avoid heap allocation in the `process()` function if you care about performance. Guide coming soon™.  

### Audio host vs audio engine

_Very WIP section_

Hum applications are split into two logical parts: the host and the engine. The primary reason for this is so that the engine can run on a separate isolate and be optimised.  

There are two types of host: `SyncAudioHost` and `IsolateAudioHost`. The former runs everything on the same (main) isolate, while the latter runs the engine on a separate thread to keep it free of GC jank. You most likely want `IsolateAudioHost` for most live applications, either is fine for offline processing. **Note that for web, only `SyncAudioHost` currently works because of limitations in how web audio works**, if it becomes a problem I'll look into web workers but it didn't seem necessary for now.  

Use an audio host like this:
```dart
final context = ProcessContext(sampleRate: 44100, vectorSize: 64);
final host = await IsolateAudioHost.spawn(context: context);
host.setGraph(root: outNode); // also possible: `setGraph(roots: [out1, out2])`.
```

The host compiles the graph by mapping the topology from the root(s) provided. To update the graph, simply call `setGraph` again at any time; the host will generate a 'diff' between the old and new graph and update the engine accordingly. 

The engine knows nothing about the nodes. Nodes instantiate an `AudioProcessor` of a type specific to the node, which takes flat input and output buffers. The host compilation step is responsible for determining the necessary order of the buffers according to the topology of the graph. In most cases, you do not even have to think about this, just tell the host what graph and output to use.  

### Outputs and drivers

`AudioOutput` defines an interface for getting audio out of the engine. What you use depends on what the situation is. If you want to just get audio out and start playing with it, try `PipedAudioOutput.ffplay` or `.sox`, requiring `ffmpeg` or `sox` in your PATH respectively.  

If you want native audio, you'll want the [hum_cpal](https://pub.dev/packages/hum_cpal) package, which gives you `CpalAudioOutput`.  

If you're building a flutter app, you'll probably want to use the helpers from the [hum_flutter](https://pub.dev/packages/hum_flutter) package, since you need a different one for web vs mobile/desktop, check the readme for details.  

```dart
final output = PipedAudioOutput.ffplay(
  numChannels: 2,
  sampleRate: 44100,
  vectorSize: 64,
); // this one requires `ffmpeg` to be installed and in PATH

await host.startPlayback(output: output);
```

Be sure to set your graph before starting playback.  

`AudioOutput` is the host side contract and maps to an `AudioOutputDriver`, which is instantiated on the engine side and handles the actual i/o. 

### Audio input

Basically the same sort of deal as output. To pull hardware input into your graph, add an `In` node (`In.mono()`, `In.stereo()`, or `In(channels: [0, 1])` to pick specific input channels) and pass an `AudioInput` alongside (or instead of) `output` in `startPlayback`:

```dart
final mic = In.mono();
final delay = Delay.mono(input: mic.outlet, time: .value(0.25));
host.setGraph(root: Out.mono(delay.outlet));

final input = CpalAudioInput(
  numChannels: inCfg.channels,
  vectorSize: vectorSize,
  deviceId: requestedInId,
  bufferFrames: 2048,
);
final output = CpalAudioOutput(
  numChannels: outCfg.channels,
  vectorSize: vectorSize,
  deviceId: requestedOutId,
  bufferFrames: 2048,
);
await host.startPlayback(input: input, output: output);
```

## Features

I'll document the library of nodes etc later, for now I just made this section to highlight a few things we **don't** have yet.  

### Upcoming
* Audio buffer handling for e.g. sampling, granular synthesis, just playing back samples
* More sophisticated music composition primitives (we already have some stuff like `Note`, `Chord`, etc, I mean more like better sequencing nodes)
* Trigger sources in node graph (to e.g. handle a transient input like a note or button press without updating the whole graph)
* Expressive DSL/fluent graph composition: think like `square(440) * 0.5 >> delay(0.1) >> out`
* A whole ton of new nodes, optimisations, etc
