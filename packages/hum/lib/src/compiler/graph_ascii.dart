import 'dart:math' as math;

import 'package:hum/hum.dart';

/// Options controlling how [formatGraphAscii] renders an audio graph.
class const GraphAsciiOptions({
  /// Reorder nodes with a chain-preserving topological DFS so signal voices
  /// stay grouped together and wire crossings are minimized.
  ///
  /// Set to `false` to preserve the exact compilation schedule order.
  final bool compactOrder = true,

  /// Include concise formatted parameter values from `AudioNode.params`.
  final bool showParams = true,

  /// Include allocated buffer slot numbers (e.g. `[slot 0]`) when available.
  final bool showSlots = false,

  /// Include upstream node/outlet references (e.g. `<- #1, #4`) on multi-input
  /// or non-trivial connections.
  final bool showInputRefs = true,
});

/// Renders an audio graph rooted at [root], [roots], or [targetOutputs] as a
/// Unicode/ASCII signal-flow diagram.
///
/// Signal flows top-to-bottom from sources (`○`) through processors (`●`) to
/// terminal outputs (`◆`).
String formatGraphAscii({
  AudioNode? root,
  List<AudioNode>? roots,
  List<Outlet>? targetOutputs,
  GraphSnapshot? snapshot,
  String? title,
  GraphAsciiOptions options = const GraphAsciiOptions(),
}) {
  final GraphSnapshot resolvedSnapshot;
  if (snapshot != null) {
    resolvedSnapshot = snapshot;
  } else {
    final result = compileGraph(
      root: root,
      roots: roots,
      targetOutputs: targetOutputs,
    );
    if (result.isFailure || result.snapshot == null) {
      final buffer = StringBuffer()..writeln('Graph compilation failed:');
      for (final diag in result.diagnostics) {
        buffer.writeln('  $diag');
      }
      return buffer.toString().trimRight();
    }
    resolvedSnapshot = result.snapshot!;
  }

  return resolvedSnapshot.toAscii(title: title, options: options);
}

/// Extension for rendering a compiled [GraphSnapshot] as an ASCII diagram.
extension GraphSnapshotAsciiExtension on GraphSnapshot {
  /// Renders this [GraphSnapshot] as a Unicode/ASCII signal-flow diagram.
  String toAscii({
    String? title,
    GraphAsciiOptions options = const GraphAsciiOptions(),
  }) {
    if (isEmpty) {
      return title != null ? '$title\n(empty graph)' : '(empty graph)';
    }

    final slotByNode = <AudioNode, SnapshotStep>{
      for (final step in steps) step.node: step,
    };

    final orderedNodes = options.compactOrder ? _orderChainFirst(nodes) : nodes;

    final nodeIndex = <AudioNode, int>{
      for (int i = 0; i < orderedNodes.length; i++) orderedNodes[i]: i,
    };

    // Determine the last step reading each outlet, plus any pinned outputs
    // that are not already consumed by a TerminalNode.
    final lastReaderStep = <Outlet, int>{};
    int edgeCount = 0;
    for (int i = 0; i < orderedNodes.length; i++) {
      for (final inlet in orderedNodes[i].inlets) {
        final source = inlet.source;
        if (source == null) continue;
        edgeCount++;
        final prev = lastReaderStep[source];
        if (prev == null || i > prev) {
          lastReaderStep[source] = i;
        }
      }
    }

    // If the graph does not end in a TerminalNode, outlets of sink nodes
    // should remain visibly live until the bottom of the diagram.
    final pinnedOutlets = <Outlet>[];
    final hasTerminalSink = orderedNodes.any((n) => n is TerminalNode);
    if (!hasTerminalSink) {
      for (final node in orderedNodes) {
        for (final outlet in node.outlets) {
          if (!lastReaderStep.containsKey(outlet)) {
            lastReaderStep[outlet] = orderedNodes.length;
            pinnedOutlets.add(outlet);
          }
        }
      }
    }

    final rails = <Outlet?>[];
    final outletCol = <Outlet, int>{};
    final rows = <({String prefix, String label})>[];
    int maxPrefixWidth = 0;

    void addRow(String prefix, String label) {
      final trimmed = prefix.trimRight();
      if (trimmed.length > maxPrefixWidth) {
        maxPrefixWidth = trimmed.length;
      }
      rows.add((prefix: trimmed, label: label));
    }

    for (int step = 0; step < orderedNodes.length; step++) {
      final node = orderedNodes[step];

      final inOutlets = <Outlet>[];
      final seenInlets = <Outlet>{};
      for (final inlet in node.inlets) {
        final source = inlet.source;
        if (source != null && seenInlets.add(source)) {
          inOutlets.add(source);
        }
      }

      final inCols = <int>{
        for (final outlet in inOutlets)
          if (outletCol.containsKey(outlet)) outletCol[outlet]!,
      };
      final deadInCols = <int>{
        for (final col in inCols)
          if (lastReaderStep[rails[col]!] == step) col,
      };

      final int nodeCol;
      if (deadInCols.isNotEmpty) {
        nodeCol = deadInCols.reduce(math.min);
      } else {
        final freeIdx = rails.indexOf(null);
        nodeCol = freeIdx >= 0 ? freeIdx : rails.length;
      }
      while (rails.length <= nodeCol) {
        rails.add(null);
      }

      final String nodeSymbol = switch (node) {
        TerminalNode() => '◆',
        _ when inOutlets.isEmpty => '○',
        _ => '●',
      };

      final spanCols = <int>{...inCols, nodeCol};
      final minSpan = spanCols.reduce(math.min);
      final maxSpan = spanCols.reduce(math.max);
      final hasSpan = inCols.isNotEmpty;

      final prefixBuf = StringBuffer();
      for (int k = 0; k < rails.length; k++) {
        final inHoriz = hasSpan && k >= minSpan && k <= maxSpan;
        final gap = (hasSpan && k >= minSpan && k < maxSpan) ? '─' : ' ';

        final String sym;
        if (k == nodeCol) {
          sym = nodeSymbol;
        } else if (inCols.contains(k)) {
          final isDead = deadInCols.contains(k);
          if (isDead) {
            if (k == minSpan) {
              sym = '╰';
            } else if (k == maxSpan) {
              sym = '╯';
            } else {
              sym = '┴';
            }
          } else {
            if (k == minSpan) {
              sym = '├';
            } else if (k == maxSpan) {
              sym = '┤';
            } else {
              sym = '┼';
            }
          }
        } else if (rails[k] != null) {
          sym = '│';
        } else if (inHoriz) {
          sym = '─';
        } else {
          sym = ' ';
        }

        prefixBuf.write(sym);
        if (k < rails.length - 1) {
          prefixBuf.write(gap);
        }
      }

      final label = _formatNodeLabel(
        node: node,
        index: step,
        nodeIndex: nodeIndex,
        snapshotStep: slotByNode[node],
        options: options,
      );
      addRow(prefixBuf.toString(), label);

      // Release dying input wires.
      for (final col in deadInCols) {
        final deadOutlet = rails[col];
        if (deadOutlet != null) {
          outletCol.remove(deadOutlet);
        }
        rails[col] = null;
      }

      // Route live output wires downward.
      final liveOutlets = <Outlet>[
        for (final outlet in node.outlets)
          if (lastReaderStep.containsKey(outlet)) outlet,
      ];

      if (liveOutlets.isNotEmpty) {
        rails[nodeCol] = liveOutlets[0];
        outletCol[liveOutlets[0]] = nodeCol;

        if (liveOutlets.length > 1) {
          final extraCols = <int>{};
          for (int j = 1; j < liveOutlets.length; j++) {
            final freeIdx = rails.indexOf(null);
            final col = freeIdx >= 0 ? freeIdx : rails.length;
            if (col == rails.length) {
              rails.add(liveOutlets[j]);
            } else {
              rails[col] = liveOutlets[j];
            }
            outletCol[liveOutlets[j]] = col;
            extraCols.add(col);
          }

          final outSpan = <int>{nodeCol, ...extraCols};
          final minOut = outSpan.reduce(math.min);
          final maxOut = outSpan.reduce(math.max);

          final forkBuf = StringBuffer();
          for (int k = 0; k < rails.length; k++) {
            final inHoriz = k >= minOut && k <= maxOut;
            final gap = (k >= minOut && k < maxOut) ? '─' : ' ';

            final String sym;
            if (k == nodeCol) {
              if (k == minOut) {
                sym = '├';
              } else if (k == maxOut) {
                sym = '┤';
              } else {
                sym = '┼';
              }
            } else if (extraCols.contains(k)) {
              if (k == minOut) {
                sym = '╭';
              } else if (k == maxOut) {
                sym = '╮';
              } else {
                sym = '┬';
              }
            } else if (rails[k] != null) {
              sym = '│';
            } else if (inHoriz) {
              sym = '─';
            } else {
              sym = ' ';
            }

            forkBuf.write(sym);
            if (k < rails.length - 1) {
              forkBuf.write(gap);
            }
          }
          addRow(forkBuf.toString(), '');
        }
      }

      while (rails.isNotEmpty && rails.last == null) {
        rails.removeLast();
      }
    }

    // If non-terminal outputs remained live, terminate them cleanly.
    if (pinnedOutlets.isNotEmpty && rails.any((o) => o != null)) {
      final endBuf = StringBuffer();
      for (int k = 0; k < rails.length; k++) {
        endBuf.write(rails[k] != null ? '▼' : ' ');
        if (k < rails.length - 1) endBuf.write(' ');
      }
      addRow(endBuf.toString(), 'graph output (${pinnedOutlets.length} ch)');
    }

    final out = StringBuffer();
    final header = title != null
        ? '$title (${orderedNodes.length} nodes, $edgeCount edges, $totalSlots buffer slots)'
        : 'Audio Graph (${orderedNodes.length} nodes, $edgeCount edges, $totalSlots buffer slots)';
    out.writeln(header);
    out.writeln('─' * header.length);

    final gutterWidth = maxPrefixWidth + 2;
    for (final row in rows) {
      if (row.label.isEmpty) {
        out.writeln(' ${row.prefix}');
      } else {
        out.writeln(' ${row.prefix.padRight(gutterWidth)}${row.label}');
      }
    }

    return out.toString().trimRight();
  }
}

/// Orders nodes using post-order DFS from sink nodes so each signal branch
/// stays grouped together while preserving valid topological order.
List<AudioNode> _orderChainFirst(List<AudioNode> topoNodes) {
  final hasDependents = <AudioNode>{};
  for (final node in topoNodes) {
    for (final inlet in node.inlets) {
      final sourceNode = inlet.source?.node;
      if (sourceNode != null) {
        hasDependents.add(sourceNode);
      }
    }
  }

  final sinks = [
    for (final node in topoNodes)
      if (!hasDependents.contains(node)) node,
  ];

  final visited = <AudioNode>{};
  final ordered = <AudioNode>[];

  void visit(AudioNode node) {
    if (!visited.add(node)) return;
    for (final inlet in node.inlets) {
      final upstream = inlet.source?.node;
      if (upstream != null) {
        visit(upstream);
      }
    }
    ordered.add(node);
  }

  for (final sink in sinks) {
    visit(sink);
  }
  for (final node in topoNodes) {
    visit(node);
  }

  return ordered;
}

String _formatNodeLabel({
  required AudioNode node,
  required int index,
  required Map<AudioNode, int> nodeIndex,
  required SnapshotStep? snapshotStep,
  required GraphAsciiOptions options,
}) {
  final buf = StringBuffer()..write('#$index ${node.runtimeType}');

  if (options.showParams) {
    final paramSummary = _formatParams(node.params);
    if (paramSummary.isNotEmpty) {
      buf.write(' ($paramSummary)');
    }
  }

  if (options.showSlots && snapshotStep != null) {
    final slots = snapshotStep.outputSlots;
    if (slots.isNotEmpty) {
      buf.write(' [slot ${slots.join(',')}]');
    }
  }

  if (options.showInputRefs) {
    final refs = <String>[];
    for (final inlet in node.inlets) {
      final source = inlet.source;
      if (source == null) continue;
      final srcIdx = nodeIndex[source.node];
      if (srcIdx == null) continue;
      final multiOut = source.node.outlets.length > 1;
      final tag = multiOut ? '#$srcIdx.${source.index}' : '#$srcIdx';
      refs.add(tag);
    }
    // Show input refs whenever there are multiple inlets, multi-outlet sources,
    // or a non-adjacent upstream connection.
    final isSimpleAdjacent =
        refs.length == 1 &&
        node.inlets.where((i) => i.source != null).first.source!.node ==
            _previousByIndex(nodeIndex, index) &&
        node.inlets
                .where((i) => i.source != null)
                .first
                .source!
                .node
                .outlets
                .length ==
            1;
    if (refs.isNotEmpty && !isSimpleAdjacent) {
      buf.write('  ← ${refs.join(', ')}');
    }
  }

  return buf.toString();
}

AudioNode? _previousByIndex(Map<AudioNode, int> nodeIndex, int index) {
  if (index <= 0) return null;
  for (final entry in nodeIndex.entries) {
    if (entry.value == index - 1) return entry.key;
  }
  return null;
}

String _formatParams(Object params) {
  final raw = params.toString().trim();
  if (raw == '()' || raw.isEmpty) return '';
  if (!raw.startsWith('(') || !raw.endsWith(')')) {
    return _truncate(raw, 60);
  }

  final inner = raw.substring(1, raw.length - 1);
  final fields = _splitTopLevel(inner);
  final kept = <String>[];

  for (final field in fields) {
    final colonIdx = field.indexOf(':');
    if (colonIdx <= 0) {
      final cleaned = _cleanValue(field.trim());
      if (cleaned != 'null') kept.add(cleaned);
      continue;
    }
    final name = field.substring(0, colonIdx).trim();
    final value = field.substring(colonIdx + 1).trim();
    if (value == 'null') continue;
    kept.add('$name: ${_cleanValue(value)}');
  }

  return kept.join(', ');
}

List<String> _splitTopLevel(String text) {
  final parts = <String>[];
  int depthParen = 0;
  int depthBracket = 0;
  int depthBrace = 0;
  int start = 0;

  for (int i = 0; i < text.length; i++) {
    switch (text[i]) {
      case '(':
        depthParen++;
      case ')':
        if (depthParen > 0) depthParen--;
      case '[':
        depthBracket++;
      case ']':
        if (depthBracket > 0) depthBracket--;
      case '{':
        depthBrace++;
      case '}':
        if (depthBrace > 0) depthBrace--;
      case ',' when depthParen == 0 && depthBracket == 0 && depthBrace == 0:
        parts.add(text.substring(start, i));
        start = i + 1;
    }
  }
  if (start < text.length) {
    parts.add(text.substring(start));
  }
  return parts;
}

String _cleanValue(String value) {
  if (value.startsWith('[') && value.endsWith(']')) {
    final inner = value.substring(1, value.length - 1).trim();
    if (inner.isEmpty) return '[]';
    final items = _splitTopLevel(inner);
    if (items.length > 4 || value.length > 36) {
      return '[${items.length} items]';
    }
    return '[${items.map((e) => _cleanValue(e.trim())).join(', ')}]';
  }

  final asDouble = double.tryParse(value);
  if (asDouble != null && !asDouble.isNaN && !asDouble.isInfinite) {
    if (asDouble == asDouble.roundToDouble() && asDouble.abs() < 1e6) {
      return asDouble.toStringAsFixed(1);
    }
    final fixed = asDouble.toStringAsFixed(3);
    return fixed
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '.0');
  }

  if (value.length > 36) {
    return '${value.substring(0, 33)}...';
  }
  return value;
}

String _truncate(String s, int maxLen) =>
    s.length <= maxLen ? s : '${s.substring(0, maxLen - 3)}...';
