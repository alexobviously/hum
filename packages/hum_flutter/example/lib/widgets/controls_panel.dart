import 'package:hum/hum.dart';
import 'package:hum_flutter/hum_flutter.dart';
import 'package:material_ui/material_ui.dart';

import '../sequencer_state.dart';

class const ControlsPanel({
  super.key,
  required final HumAudioController audio,
  required final SequencerState state,
  required final VoidCallback onTogglePlay,
  required final VoidCallback onRandomizeSettings,
  required final VoidCallback onChanged,
}) extends StatelessWidget {
  void _update(VoidCallback mutate) {
    mutate();
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sampleRate = audio.session?.context.sampleRate;

    return Card(
      margin: const .all(16),
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: .circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const .all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: audio.isStarting ? null : onTogglePlay,
                  icon: Icon(audio.isPlaying ? Icons.stop : Icons.play_arrow),
                  label: Text(audio.isPlaying ? 'Stop' : 'Play'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                onPressed: onRandomizeSettings,
                tooltip: 'Randomize settings',
                icon: const Icon(Icons.casino_outlined),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            audio.lastError != null
                ? 'Error: ${audio.lastError}'
                : audio.isPlaying
                ? 'Playing @ ${sampleRate ?? '-'} Hz'
                : 'Stopped',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: audio.lastError != null
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 24),
          Row(
            children: [
              SizedBox(
                width: 84,
                child: DropdownButtonFormField<String>(
                  initialValue: state.rootKey,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Key',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final key in availableKeys)
                      DropdownMenuItem(value: key, child: Text(key)),
                  ],
                  onChanged: (v) {
                    if (v != null) _update(() => state.rootKey = v);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<ScalePattern>(
                  initialValue: state.scalePattern,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Scale',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final pattern in availableScales)
                      DropdownMenuItem(
                        value: pattern,
                        child: Text(pattern.name, overflow: .ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) _update(() => state.scalePattern = v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ParamSlider(
            label: 'Tempo',
            valueText: '${state.bpm.round()} BPM',
            value: state.bpm,
            min: 60,
            max: 200,
            onChanged: (v) => _update(() => state.bpm = v),
          ),
          const _SectionHeader('Envelope'),
          _ParamSlider(
            label: 'Attack',
            valueText: '${(state.attack * 1000).round()} ms',
            value: state.attack,
            min: 0.002,
            max: 0.4,
            onChanged: (v) => _update(() => state.attack = v),
          ),
          _ParamSlider(
            label: 'Decay',
            valueText: '${(state.decay * 1000).round()} ms',
            value: state.decay,
            min: 0.02,
            max: 0.6,
            onChanged: (v) => _update(() => state.decay = v),
          ),
          _ParamSlider(
            label: 'Sustain',
            valueText: '${(state.sustain * 100).round()}%',
            value: state.sustain,
            min: 0.0,
            max: 1.0,
            onChanged: (v) => _update(() => state.sustain = v),
          ),
          _ParamSlider(
            label: 'Release',
            valueText: '${(state.release * 1000).round()} ms',
            value: state.release,
            min: 0.01,
            max: 0.6,
            onChanged: (v) => _update(() => state.release = v),
          ),
          const _SectionHeader('Oscillator Mix'),
          _ParamSlider(
            label: 'Sine',
            valueText: '${(state.sineLevel * 100).round()}%',
            value: state.sineLevel,
            min: 0,
            max: 1,
            onChanged: (v) => _update(() => state.sineLevel = v),
          ),
          _ParamSlider(
            label: 'Square',
            valueText: '${(state.squareLevel * 100).round()}%',
            value: state.squareLevel,
            min: 0,
            max: 1,
            onChanged: (v) => _update(() => state.squareLevel = v),
          ),
          _ParamSlider(
            label: 'Saw',
            valueText: '${(state.sawLevel * 100).round()}%',
            value: state.sawLevel,
            min: 0,
            max: 1,
            onChanged: (v) => _update(() => state.sawLevel = v),
          ),
          const _SectionHeader('Filter & FX'),
          _ParamSlider(
            label: 'Cutoff',
            valueText: '${state.cutoff.round()} Hz',
            value: state.cutoff,
            min: 150,
            max: 12000,
            onChanged: (v) => _update(() => state.cutoff = v),
          ),
          _ParamSlider(
            label: 'Resonance',
            valueText: state.resonance.toStringAsFixed(1),
            value: state.resonance,
            min: 0.5,
            max: 6.0,
            onChanged: (v) => _update(() => state.resonance = v),
          ),
          _ParamSlider(
            label: 'Delay Mix',
            valueText: '${(state.delayMix * 100).round()}%',
            value: state.delayMix,
            min: 0,
            max: 0.7,
            onChanged: (v) => _update(() => state.delayMix = v),
          ),
          _ParamSlider(
            label: 'Delay Feedback',
            valueText: '${(state.delayFeedback * 100).round()}%',
            value: state.delayFeedback,
            min: 0,
            max: 0.85,
            onChanged: (v) => _update(() => state.delayFeedback = v),
          ),
          _ParamSlider(
            label: 'Reverb Mix',
            valueText: '${(state.reverbMix * 100).round()}%',
            value: state.reverbMix,
            min: 0,
            max: 0.8,
            onChanged: (v) => _update(() => state.reverbMix = v),
          ),
          Row(
            mainAxisAlignment: .spaceBetween,
            children: [
              const _SectionHeader('Bitcrusher'),
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: state.bitcrushEnabled,
                  onChanged: (v) => _update(() => state.bitcrushEnabled = v),
                ),
              ),
            ],
          ),
          if (state.bitcrushEnabled) ...[
            _ParamSlider(
              label: 'Bit Depth',
              valueText: '${state.bitDepth.round()} bit',
              value: state.bitDepth,
              min: 2,
              max: 16,
              onChanged: (v) =>
                  _update(() => state.bitDepth = v.roundToDouble()),
            ),
            _ParamSlider(
              label: 'Downsample',
              valueText: '${state.downsample.toStringAsFixed(1)}x',
              value: state.downsample,
              min: 1,
              max: 16,
              onChanged: (v) => _update(() => state.downsample = v),
            ),
            _ParamSlider(
              label: 'Crush Mix',
              valueText: '${(state.bitcrushMix * 100).round()}%',
              value: state.bitcrushMix,
              min: 0,
              max: 1,
              onChanged: (v) => _update(() => state.bitcrushMix = v),
            ),
          ],
        ],
      ),
    );
  }
}

class const _SectionHeader(final String title) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const .only(top: 12, bottom: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: .w600,
        ),
      ),
    );
  }
}

class const _ParamSlider({
  required final String label,
  required final String valueText,
  required final double value,
  required final double min,
  required final double max,
  required final ValueChanged<double> onChanged,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: .start,
      children: [
        Row(
          mainAxisAlignment: .spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(
              valueText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
