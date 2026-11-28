## 0.1.2

* Optimisation: engine topology epochs, allowing nodes that should change when topology changes to more easily detect changes, without comparing every buffer, e.g. nodes that cache SIMD views.
* Optimisation: use graph colouring to reuse buffers once their lifecycle has ended, e.g. A -> B -> C, A's output buffer is not needed after B, so we can reuse it for C.
* Wavetable synthesis: `WavetableOscillator`, with `Wavetable` buffer wrapper and utilities.
* `StepSequencer.mode` (`enum StepMode`): allows reverse, random, etc step selection instead of just forward.
* `KarplusStrong` v2, params: `pickHardness`, `pickPosition`, `damping`.
* Safety: guard against out of bounds/NaN/infinity in audio output.
* `Expander` and `NoiseGate` nodes.

## 0.1.1

* New nodes: `PitchDetector`, `SamplePlayer`, `Branch`.
* Added telemetry to `Autocorrelation` node.
* Added `AudioBuffer` system for allocating buffers to be used in e.g. `SamplePlayer`.

## 0.1.0

* Initial release.
