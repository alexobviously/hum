import 'dart:typed_data';

import 'package:hum/hum.dart';

abstract class AudioProcessor {
  void update(Object params);

  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  );

  // probably like some init & dispose stuff etc
}
