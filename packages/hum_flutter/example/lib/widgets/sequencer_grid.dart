import 'package:material_ui/material_ui.dart';

import '../sequencer_state.dart';

class const SequencerGrid({
  super.key,
  required final SequencerState state,
  required final void Function(int step, int noteIdx) onToggleCell,
  required final VoidCallback onRandomize,
  required final VoidCallback onClear,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notes = state.notes;
    const cellSize = 44.0;
    const gap = 8.0;

    return Padding(
      padding: const .all(16),
      child: FittedBox(
        fit: .scaleDown,
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            // TODO(telemetry/#5): Drive this playhead indicator row directly
            // from the audio engine's StepSequencer telemetry stream once the
            // telemetry pipeline is implemented, highlighting the active step
            // column in real time!
            Row(
              children: [
                const SizedBox(width: 52 + gap),
                for (int step = 0; step < SequencerState.numSteps; step++) ...[
                  Container(
                    width: cellSize,
                    height: 8,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: .circular(4),
                    ),
                  ),
                  if (step < SequencerState.numSteps - 1)
                    const SizedBox(width: gap),
                ],
              ],
            ),
            const SizedBox(height: 10),
            // Highest note at top, lowest note at bottom.
            for (int row = SequencerState.numNotes - 1; row >= 0; row--) ...[
              Row(
                children: [
                  Container(
                    width: 52,
                    height: cellSize,
                    alignment: .center,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: .circular(10),
                    ),
                    child: Text(
                      notes[row].name,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: .w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: gap),
                  for (
                    int step = 0;
                    step < SequencerState.numSteps;
                    step++
                  ) ...[
                    _StepPad(
                      size: cellSize,
                      active: state.steps[step] == row,
                      onTap: () => onToggleCell(step, row),
                    ),
                    if (step < SequencerState.numSteps - 1)
                      const SizedBox(width: gap),
                  ],
                ],
              ),
              if (row > 0) const SizedBox(height: gap),
            ],
            const SizedBox(height: 14),
            Row(
              spacing: 8,
              children: [
                const SizedBox(width: 52 + gap),
                OutlinedButton.icon(
                  onPressed: onRandomize,
                  label: const Text('Randomize'),
                  icon: const Icon(Icons.casino_outlined),
                ),
                OutlinedButton.icon(
                  onPressed: onClear,
                  label: const Text('Clear'),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class const _StepPad({
  required final double size,
  required final bool active,
  required final VoidCallback onTap,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: active ? scheme.primary : scheme.surfaceContainerHighest,
      borderRadius: .circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: .circular(10),
        child: SizedBox(width: size, height: size),
      ),
    );
  }
}
