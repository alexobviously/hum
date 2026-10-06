import 'package:dsp/src/core/audio_processor.dart';
import 'package:dsp/src/core/audio_port.dart';

abstract class AudioNode<T extends AudioProcessor> {
  List<Inlet> get inlets;
  List<Outlet> get outlets;

  T createProcessor();
  void updateProcessor(T processor);
}
