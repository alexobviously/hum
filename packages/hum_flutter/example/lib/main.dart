import 'dart:async';

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
        colorScheme: .fromSeed(
          seedColor: const Color(0xffabe188),
          brightness: .light,
        ),
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
  StreamSubscription<int>? _playheadSub;
  int? _activeStep;

  @override
  void dispose() {
    unawaited(_playheadSub?.cancel());
    _audio.dispose();
    super.dispose();
  }

  void _syncGraph() {
    setState(() {});
    final session = _audio.session;
    if (session == null) return;
    _audio.setGraph(root: _state.buildGraph(session));
  }

  Future<void> _togglePlay() async {
    if (_audio.isPlaying || _audio.isStarting) {
      await _playheadSub?.cancel();
      _playheadSub = null;
      if (mounted) setState(() => _activeStep = null);
      await _audio.stop();
      return;
    }
    try {
      await _audio.start(buildGraph: _state.buildGraph);
      final seq = _state.freqSequencer;
      if (seq != null) {
        await _playheadSub?.cancel();
        _playheadSub = _audio.telemetryOf(seq)?.stream.listen((step) {
          if (mounted && _activeStep != step) {
            setState(() => _activeStep = step);
          }
        });
      }
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
          activeStep: _audio.isPlaying ? _activeStep : null,
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
