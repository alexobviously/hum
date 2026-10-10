import 'dart:typed_data';

import 'package:dsp/src/core/audio_node.dart';
import 'package:dsp/src/core/audio_port.dart';
import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/process_context.dart';

class Dac implements AudioNode<DacProcessor> {
  final List<Outlet> channels;
  const Dac({required this.channels});

  @override
  List<Inlet> get inlets => List.generate(
    channels.length,
    (i) => Inlet(node: this, index: i, source: channels[i]),
  );

  @override
  List<Outlet> get outlets => [];

  @override
  DacProcessor createProcessor() => DacProcessor();

  @override
  Object get params => ();
}

class DacProcessor implements AudioProcessor {
  DacProcessor();
  factory build(Object params) => DacProcessor();

  @override
  void update(Object params) {}

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    // no-op
  }
}
