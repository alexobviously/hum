import 'package:hum/hum.dart';

// TODO: make this more useful? i.e. extract boilerplate to here?
abstract class OscillatorNode<T extends AudioProcessor> extends AudioNode<T> {
  OscillatorNode();

  ControlParam<double> get frequency;
  Outlet get outlet;
}

extension OscillatorMapRange on OscillatorNode {
  /// Linearly remaps this bipolar oscillator signal `[-1.0, 1.0]` to `[outLow, outHigh]`.
  MapRange mapRange(double outLow, double outHigh) => MapRange.bipolar(
    input: outlet,
    outLow: outLow,
    outHigh: outHigh,
  );
}
