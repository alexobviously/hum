import 'dart:async';
import 'dart:typed_data';

import 'package:hum/hum.dart';

abstract class AudioProcessor {
  void update(Object params);

  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  );
}

/// An interface for [AudioProcessor]s that hold external resources
/// (such as file handles or child subprocesses) requiring explicit cleanup
/// upon node removal or host disposal.
abstract interface class DisposableAudioProcessor extends AudioProcessor {
  FutureOr<void> dispose();
}

/// An interface for [AudioProcessor]s that read directly from the engine's
/// hardware/host input buffers (such as [InProcessor]).
abstract interface class InputAwareProcessor extends AudioProcessor {
  /// Binds the engine's pre-allocated input channel buffers to this processor.
  void bindInputs(List<Float32List> engineInputs);
}

/// Callback that resolves a [BufferId] to its [AudioBuffer] inside the engine.
typedef BufferLookup = AudioBuffer? Function(BufferId id);

/// An interface for [AudioProcessor]s that read from host-loaded [AudioBuffer]s
/// stored in [AudioEngine] (such as [SamplePlayerProcessor]).
abstract interface class BufferAwareProcessor extends AudioProcessor {
  /// Binds [lookup] to this processor so it can resolve and cache its
  /// [AudioBuffer] reference(s).
  ///
  /// Called when the processor is installed and whenever buffers are loaded
  /// or unloaded in the engine.
  void bindBuffers(BufferLookup lookup);
}
