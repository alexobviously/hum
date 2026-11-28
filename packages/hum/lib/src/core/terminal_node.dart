import 'package:hum/hum.dart';

/// Base class for nodes that terminate an audio signal path or designate graph output channels.
///
/// Terminal nodes have no outlets ([outlets] is always empty) and consume upstream
/// signals for master bus playback, disk recording, or subprocess piping.
abstract class TerminalNode<T extends AudioProcessor>() extends AudioNode<T> {
  @override
  List<Outlet> get outlets => const [];
}
