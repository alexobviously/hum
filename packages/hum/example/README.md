# hum Examples

This directory contains executable demonstrations, audio examples, and CLI utilities for the `hum` audio DSP engine.

## Running Examples

From the root of the repository, execute any example with `dart run`:

```bash
# Synth voice demo (saw + SVF + tube saturation + stereo chorus + delay)
# Just so there's something that shows on pub.dev
dart run packages/hum/example/main.dart

# Modular demos
dart run packages/hum/example/demos/comb_filter_demo.dart
dart run packages/hum/example/demos/chorus_demo.dart
dart run packages/hum/example/demos/step_sequencer_demo.dart
dart run packages/hum/example/demos/karplus_demo.dart
dart run packages/hum/example/demos/slew_demo.dart
dart run packages/hum/example/demos/tah_demo.dart
dart run packages/hum/example/demos/chance_demo.dart
dart run packages/hum/example/demos/clock_demo.dart
dart run packages/hum/example/demos/pipeline_demo.dart
dart run packages/hum/example/demos/sine_wav_demo.dart
dart run packages/hum/example/demos/sah_demo.dart
```

Rendered `.wav` files are placed into the `tmp/` directory for listening:

```bash
afplay tmp/example_synth.wav
```

