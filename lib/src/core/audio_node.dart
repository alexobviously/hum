import 'package:hum/hum.dart';

abstract class AudioNode<T extends AudioProcessor> {
  List<Inlet> get inlets;
  List<Outlet> get outlets;

  T createProcessor();

  Object get params;
}
