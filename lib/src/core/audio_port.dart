import 'package:hum/hum.dart';

class Inlet({
  required final AudioNode node,
  required final int index,
  required final Outlet? source,
}) {
  @override
  bool operator ==(Object other) {
    if (other is! Inlet) return false;
    return node == other.node && index == other.index;
  }

  @override
  int get hashCode => Object.hash(node, index);
}

class Outlet({required final AudioNode node, required final int index}) {
  @override
  bool operator ==(Object other) {
    if (other is! Outlet) return false;
    return node == other.node && index == other.index;
  }

  @override
  int get hashCode => Object.hash(node, index);
}

class AudioPort({required final AudioNode node, required final int index}) {
  @override
  bool operator ==(Object other) {
    if (other is! AudioPort) return false;
    return node == other.node && index == other.index;
  }

  @override
  int get hashCode => Object.hash(node, index);
}
