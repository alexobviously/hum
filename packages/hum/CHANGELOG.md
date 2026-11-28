## 0.1.2

* Optimisation: engine topology epochs, allowing nodes that should change when topology changes to more easily detect changes, without comparing every buffer, e.g. nodes that cache SIMD views.
* Optimisation: use graph colouring to reuse buffers once their lifecycle has ended, e.g. A -> B -> C, A's output buffer is not needed after B, so we can reuse it for C.

## 0.1.1

* New nodes: `PitchDetector`, `SamplePlayer`, `Branch`.
* Added telemetry to `Autocorrelation` node.
* Added `AudioBuffer` system for allocating buffers to be used in e.g. `SamplePlayer`.

## 0.1.0

* Initial release.
