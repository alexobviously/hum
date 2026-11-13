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
