import 'package:hum/hum.dart';

// TODO: make this more useful? i.e. extract boilerplate to here?
abstract class OscillatorNode<T extends AudioProcessor> extends AudioNode<T> {
  const OscillatorNode();

  ControlParam<double> get frequency;
  Outlet get outlet;
}

extension OscillatorScale on OscillatorNode {
  Scale scale(double outLow, double outHigh) => Scale(
    input: outlet,
    inLow: const .value(-1.0),
    inHigh: const .value(1.0),
    outLow: .value(outLow),
    outHigh: .value(outHigh),
  );
}
