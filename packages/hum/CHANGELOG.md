## 0.1.2

* Optimisation: engine topology epochs, allowing nodes that should change when topology changes to easily detect that, without comparing every buffer, e.g. nodes that cache simd views.

## 0.1.1

* New nodes: `PitchDetector`, `SamplePlayer`, `Branch`.
* Added telemetry to `Autocorrelation` node.
* Added `AudioBuffer` system for allocating buffers to be used in e.g. `SamplePlayer`.

## 0.1.0

* Initial release.
