import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/audio_port.dart';

abstract class AudioNode<T extends AudioProcessor> {
  List<AudioPort> get inputs;
  List<AudioPort> get outputs;

  T createProcessor();
  void updateProcessor(T processor);
}
