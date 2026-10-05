import 'dart:typed_data';

import 'package:dsp/src/core/process_context.dart';

abstract class AudioProcessor {
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  );

  // probably like some init & dispose stuff etc
}
