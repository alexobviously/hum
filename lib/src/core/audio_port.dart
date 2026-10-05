import 'package:dsp/src/core/audio_node.dart';

class AudioPort({required final AudioNode node, required final int index}) {
  @override
  bool operator ==(Object other) {
    if (other is! AudioPort) return false;
    return node == other.node && index == other.index;
  }

  @override
  int get hashCode => Object.hash(node, index);
}
