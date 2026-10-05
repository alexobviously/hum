import 'dart:typed_data';

import 'package:dsp/src/core/audio_node.dart';
import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/process_context.dart';

/// A single step in the linear execution schedule.
class RenderStep {
  final AudioNode node;
  final AudioProcessor processor;
  final List<Float32List> inputs;
  final List<Float32List> outputs;

  const RenderStep({
    required this.node,
    required this.processor,
    required this.inputs,
    required this.outputs,
  });

  /// Executes this processor synchronously using its pre-mapped buffers.
  @pragma('vm:prefer-inline')
  void process(ProcessContext context) {
    processor.process(context, inputs, outputs);
  }
}

/// A compiled, linear audio rendering pipeline.
class AudioPipeline {
  final ProcessContext context;
  final List<RenderStep> steps;

  /// The output buffers of the pipeline (one [Float32List] per output channel).
  final List<Float32List> outputs;

  AudioPipeline({
    required this.context,
    required this.steps,
    required this.outputs,
  });

  /// The number of output channels.
  int get numChannels => outputs.length;

  /// Processes one block of audio across all scheduled nodes.
  ///
  /// Zero heap allocations occur during this call.
  @pragma('vm:prefer-inline')
  void process() {
    for (int i = 0; i < steps.length; i++) {
      steps[i].process(context);
    }
  }

  /// Retrieves the runtime [AudioProcessor] created for [node].
  T processorOf<T extends AudioProcessor>(AudioNode<T> node) {
    for (final step in steps) {
      if (identical(step.node, node)) {
        return step.processor as T;
      }
    }
    throw StateError('Node $node is not present in this pipeline.');
  }

  /// Updates the processor corresponding to [target] using [newSpec].
  void update<T extends AudioProcessor>(
    AudioNode<T> target,
    AudioNode<T> newSpec,
  ) {
    final processor = processorOf(target);
    newSpec.updateProcessor(processor);
  }
}
