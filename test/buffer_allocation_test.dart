import 'package:hum/hum.dart';
import 'package:test/test.dart';

/// A bare-bones node with arbitrary wiring, for testing graph structure.
class _Node extends AudioNode<AudioProcessor> {
  _Node({int numOutlets = 1, List<Outlet?> sources = const []}) {
    inlets = [
      for (final (i, source) in sources.indexed)
        Inlet(node: this, index: i, source: source),
    ];
    outlets = [
      for (var i = 0; i < numOutlets; i++) Outlet(node: this, index: i),
    ];
  }

  @override
  late final List<Inlet> inlets;

  @override
  late final List<Outlet> outlets;

  @override
  AudioProcessor createProcessor() => throw UnimplementedError();

  @override
  List<Object?> get fixedProps => const [];

  @override
  List<Object?> get dynamicProps => const [];

  @override
  Object get params => ();
}

/// Asserts that no two outlets that are live at the same time share a slot.
void _expectNoLiveOverlap(
  List<AudioNode> nodes,
  BufferAllocation allocation, {
  Iterable<Outlet> pinned = const [],
}) {
  final ranges = computeLiveRanges(nodes, pinned: pinned).entries.toList();
  for (final (i, a) in ranges.indexed) {
    for (final b in ranges.skip(i + 1)) {
      final overlaps =
          a.value.start <= b.value.end && b.value.start <= a.value.end;
      if (overlaps) {
        expect(
          allocation.slotOf(a.key),
          isNot(allocation.slotOf(b.key)),
          reason: '${a.key} and ${b.key} are live simultaneously',
        );
      }
    }
  }
}

void main() {
  group('computeLiveRanges', () {
    test('spans from producer to last consumer', () {
      final a = _Node();
      final b = _Node(sources: [a.outlets[0]]);
      final c = _Node(sources: [a.outlets[0], b.outlets[0]]);

      final ranges = computeLiveRanges([a, b, c]);

      expect(ranges[a.outlets[0]], (start: 0, end: 2));
      expect(ranges[b.outlets[0]], (start: 1, end: 2));
      expect(ranges[c.outlets[0]], (start: 2, end: 2));
    });

    test('pinned outlets stay live past the last step', () {
      final a = _Node();
      final b = _Node(sources: [a.outlets[0]]);

      final ranges = computeLiveRanges([a, b], pinned: [b.outlets[0]]);

      expect(ranges[b.outlets[0]], (start: 1, end: 2));
    });

    test('throws if nodes are not in topological order', () {
      final a = _Node();
      final b = _Node(sources: [a.outlets[0]]);

      expect(() => computeLiveRanges([b, a]), throwsArgumentError);
    });

    test('throws if a pinned outlet is not scheduled', () {
      final a = _Node();
      final stray = _Node();

      expect(
        () => computeLiveRanges([a], pinned: [stray.outlets[0]]),
        throwsArgumentError,
      );
    });
  });

  group('allocateBufferSlots', () {
    test('empty schedule needs no slots', () {
      final allocation = allocateBufferSlots([]);
      expect(allocation.totalSlots, 0);
      expect(allocation.slots, isEmpty);
    });

    test('a long chain ping-pongs between two slots', () {
      final nodes = <_Node>[_Node()];
      for (var i = 0; i < 9; i++) {
        nodes.add(_Node(sources: [nodes.last.outlets[0]]));
      }

      final allocation = allocateBufferSlots(nodes);

      expect(allocation.totalSlots, 2);
      _expectNoLiveOverlap(nodes, allocation);
    });

    test('parallel branches need one slot each, plus the mixed result', () {
      final sources = [for (var i = 0; i < 4; i++) _Node()];
      final mix = _Node(sources: [for (final s in sources) s.outlets[0]]);

      final allocation = allocateBufferSlots([...sources, mix]);

      // All four sources are live at the mix step, and the mix's output
      // can't share with its inputs.
      expect(allocation.totalSlots, 5);
      _expectNoLiveOverlap([...sources, mix], allocation);
    });

    test('slot count equals the peak number of live buffers', () {
      // a -> b -> c, and a also feeds d, which joins with c.
      final a = _Node();
      final b = _Node(sources: [a.outlets[0]]);
      final c = _Node(sources: [b.outlets[0]]);
      final d = _Node(sources: [a.outlets[0], c.outlets[0]]);
      final nodes = [a, b, c, d];

      final allocation = allocateBufferSlots(nodes);

      final ranges = computeLiveRanges(nodes);
      final peak = [
        for (var step = 0; step < nodes.length; step++)
          ranges.values.where((r) => r.start <= step && step <= r.end).length,
      ].reduce((a, b) => a > b ? a : b);

      expect(allocation.totalSlots, peak);
      _expectNoLiveOverlap(nodes, allocation);
    });

    test('unused outlets still get a slot, freed afterwards', () {
      final a = _Node(numOutlets: 2);
      final b = _Node(sources: [a.outlets[0]]);

      final allocation = allocateBufferSlots([a, b]);

      expect(allocation.slots, hasLength(3));
      _expectNoLiveOverlap([a, b], allocation);
    });

    test('unconnected inlets are ignored', () {
      final a = _Node(sources: [null]);
      final b = _Node(sources: [a.outlets[0], null]);

      final allocation = allocateBufferSlots([a, b]);

      expect(allocation.totalSlots, 2);
    });

    test('pinned outlets are never reused', () {
      final a = _Node();
      final b = _Node(sources: [a.outlets[0]]);
      final c = _Node(sources: [b.outlets[0]]);
      final d = _Node(sources: [c.outlets[0]]);
      final nodes = [a, b, c, d];
      final pinned = [b.outlets[0]];

      final allocation = allocateBufferSlots(nodes, pinned: pinned);

      _expectNoLiveOverlap(nodes, allocation, pinned: pinned);
      expect(
        allocation.slotOf(b.outlets[0]),
        isNot(allocation.slotOf(c.outlets[0])),
      );
      expect(
        allocation.slotOf(b.outlets[0]),
        isNot(allocation.slotOf(d.outlets[0])),
      );
    });

    test('is deterministic and does not mutate its input', () {
      final a = _Node();
      final b = _Node(sources: [a.outlets[0]]);
      final c = _Node(sources: [b.outlets[0]]);
      final nodes = [a, b, c];

      final first = allocateBufferSlots(nodes);
      final second = allocateBufferSlots(nodes);

      expect(nodes, [a, b, c]);
      expect(second.slots, first.slots);
    });

    test('slotOf throws for unknown outlets', () {
      final allocation = allocateBufferSlots([_Node()]);
      expect(() => allocation.slotOf(_Node().outlets[0]), throwsStateError);
    });

    group('in-place processing', () {
      test('reuses the input slot when the node is its last reader', () {
        final a = _Node();
        final b = _Node(sources: [a.outlets[0]]);
        final c = _Node(sources: [b.outlets[0]]);
        final nodes = [a, b, c];

        final allocation = allocateBufferSlots(
          nodes,
          canProcessInPlace: (_) => true,
        );

        expect(allocation.totalSlots, 1);
        expect(
          allocation.slotOf(b.outlets[0]),
          allocation.slotOf(a.outlets[0]),
        );
      });

      test('does not reuse the slot if another node still reads it', () {
        final a = _Node();
        final b = _Node(sources: [a.outlets[0]]);
        final c = _Node(sources: [a.outlets[0]]);
        final nodes = [a, b, c];

        final allocation = allocateBufferSlots(
          nodes,
          canProcessInPlace: (node) => node == b,
        );

        expect(
          allocation.slotOf(b.outlets[0]),
          isNot(allocation.slotOf(a.outlets[0])),
        );
        _expectNoLiveOverlap(nodes, allocation);
      });

      test('does not reuse a slot read through multiple inlets', () {
        final a = _Node();
        final b = _Node(sources: [a.outlets[0], a.outlets[0]], numOutlets: 2);
        final nodes = [a, b];

        final allocation = allocateBufferSlots(
          nodes,
          canProcessInPlace: (_) => true,
        );

        expect(
          allocation.slotOf(b.outlets[0]),
          isNot(allocation.slotOf(a.outlets[0])),
        );
        expect(
          allocation.slotOf(b.outlets[1]),
          isNot(allocation.slotOf(a.outlets[0])),
        );
      });

      test('only aliases output i with input i', () {
        final a = _Node();
        final b = _Node();
        // Swaps inputs: output 0 must not take input 1's slot and vice versa,
        // but here both die at this node, so only same-index reuse is allowed.
        final c = _Node(
          sources: [a.outlets[0], b.outlets[0]],
          numOutlets: 2,
        );
        final nodes = [a, b, c];

        final allocation = allocateBufferSlots(
          nodes,
          canProcessInPlace: (_) => true,
        );

        expect(allocation.totalSlots, 2);
        expect(
          allocation.slotOf(c.outlets[0]),
          allocation.slotOf(a.outlets[0]),
        );
        expect(
          allocation.slotOf(c.outlets[1]),
          allocation.slotOf(b.outlets[0]),
        );
      });

      test('never overwrites a pinned input', () {
        final a = _Node();
        final b = _Node(sources: [a.outlets[0]]);
        final nodes = [a, b];
        final pinned = [a.outlets[0]];

        final allocation = allocateBufferSlots(
          nodes,
          pinned: pinned,
          canProcessInPlace: (_) => true,
        );

        expect(allocation.totalSlots, 2);
      });
    });

    test('works on a real compiled graph', () {
      final sine = SineOscillator(frequency: .value(440));
      final mult = Mult.mono(value: .value(0.5), input: sine.outlet);
      final pan = StereoPan(input: mult.outlets[0], pan: .value(0.0));
      final dac = Dac(channels: [pan.left, pan.right]);

      final sorted = topologicalSort(discoverNodes([dac]));
      final allocation = allocateBufferSlots(
        sorted,
        pinned: [pan.left, pan.right],
      );

      _expectNoLiveOverlap(sorted, allocation, pinned: [pan.left, pan.right]);
      final naive = sorted.fold(0, (sum, node) => sum + node.outlets.length);
      expect(allocation.totalSlots, lessThanOrEqualTo(naive));
    });
  });
}
