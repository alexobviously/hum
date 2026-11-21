import 'package:hum_flutter/hum_flutter.dart';
import 'package:material_ui/material_ui.dart';

import 'sequencer_state.dart';
import 'widgets/controls_panel.dart';
import 'widgets/sequencer_grid.dart';

void main() {
  runApp(const HumSequencerApp());
}

class const HumSequencerApp({super.key}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hum Step Sequencer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: .fromSeed(seedColor: Colors.orange, brightness: .light),
        useMaterial3: true,
      ),
      home: const SequencerPage(),
    );
  }
}

class const SequencerPage({super.key}) extends StatefulWidget {
  @override
  State<SequencerPage> createState() => _SequencerPageState();
}

class _SequencerPageState extends State<SequencerPage> {
  final _audio = HumAudioController();
  final _state = SequencerState();

  @override
  void dispose() {
    _audio.dispose();
    super.dispose();
  }

  void _syncGraph() {
    setState(() {});
    final session = _audio.session;
    if (session == null || session.isDisposed) return;
    session.setGraph(root: _state.buildGraph(session));
  }

  Future<void> _togglePlay() async {
    if (_audio.isPlaying || _audio.isStarting) {
      await _audio.stop();
      return;
    }
    try {
      await _audio.start(buildGraph: _state.buildGraph);
    } catch (_) {
      // Error is already stored on `_audio.lastError`.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _audio,
      builder: (context, _) {
        final wide = MediaQuery.sizeOf(context).width >= 780;

        final controls = ControlsPanel(
          audio: _audio,
          state: _state,
          onTogglePlay: _togglePlay,
          onRandomizeSettings: () {
            _state.randomizeSettings();
            _syncGraph();
          },
          onChanged: _syncGraph,
        );

        final grid = SequencerGrid(
          state: _state,
          onToggleCell: (step, noteIdx) {
            _state.toggleCell(step, noteIdx);
            _syncGraph();
          },
          onRandomize: () {
            _state.randomizeSequence();
            _syncGraph();
          },
          onClear: () {
            _state.clearSequence();
            _syncGraph();
          },
        );

        return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
          body: SafeArea(
            child: wide
                ? Row(
                    children: [
                      SizedBox(width: 300, child: controls),
                      Expanded(child: Center(child: grid)),
                    ],
                  )
                : ListView(
                    padding: const .all(16),
                    children: [grid, const SizedBox(height: 20), controls],
                  ),
          ),
        );
      },
    );
  }
}
