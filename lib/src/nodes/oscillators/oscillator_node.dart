import 'package:dsp/dsp.dart';

abstract class OscillatorNode<T extends AudioProcessor>
    implements AudioNode<T> {
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
