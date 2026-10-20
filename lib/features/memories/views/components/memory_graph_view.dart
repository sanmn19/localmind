import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localmind/core/theme/colors.dart';
import 'package:localmind/features/memories/data/models/memory.dart';

/// The relational view: one node per memory, one labelled edge per relation.
/// Positions are deterministic (a simple circular layout) so the graph never
/// jumps between rebuilds; tapping a node opens its sheet.
class MemoryGraphView extends StatelessWidget {
  const MemoryGraphView({
    super.key,
    required this.memories,
    required this.relations,
    required this.isDark,
    required this.onTap,
  });

  final List<Memory> memories;
  final List<MemoryRelation> relations;
  final bool isDark;
  final ValueChanged<Memory> onTap;

  @override
  Widget build(BuildContext context) {
    if (memories.isEmpty) {
      return Center(
        child: Text(
          'No memories yet.',
          style: TextStyle(
            color: isDark ? AppColors.darkMutedText : AppColors.lightMutedText,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth,
          math.max(320, constraints.maxHeight),
        );
        final positions = _positions(size);
        final byId = {for (final memory in memories) memory.id: memory};
        final accent = isDark ? AppColors.darkAccent : AppColors.lightAccent;
        final muted = isDark ? AppColors.darkMutedText : AppColors.lightMutedText;
        final edges = relations.where(
          (relation) =>
              byId.containsKey(relation.fromMemoryId) &&
              byId.containsKey(relation.toMemoryId),
        );
        return GestureDetector(
          onTapUp: (details) {
            final local = details.localPosition;
            for (final memory in memories) {
              final point = positions[memory.id];
              if (point == null) continue;
              if ((point - local).distance <= 34) {
                onTap(memory);
                return;
              }
            }
          },
          child: CustomPaint(
            size: size,
            painter: _GraphPainter(
              memories: memories,
              positions: positions,
              relations: edges,
              accent: accent,
              muted: muted,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }

  Map<String, Offset> _positions(Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.36;
    return {
      for (final (index, memory) in memories.indexed)
        memory.id: center +
            Offset(
              math.cos(2 * math.pi * index / memories.length) * radius,
              math.sin(2 * math.pi * index / memories.length) * radius,
            ),
    };
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.memories,
    required this.positions,
    required this.relations,
    required this.accent,
    required this.muted,
  });

  final List<Memory> memories;
  final Map<String, Offset> positions;
  final Iterable<MemoryRelation> relations;
  final Color accent;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    final edgePaint = Paint()
      ..color = muted.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final nodePaint = Paint()..color = accent;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (final relation in relations) {
      final from = positions[relation.fromMemoryId];
      final to = positions[relation.toMemoryId];
      if (from == null || to == null) continue;
      canvas.drawLine(from, to, edgePaint);
    }
    for (final memory in memories) {
      final point = positions[memory.id];
      if (point == null) continue;
      canvas.drawCircle(point, 6, nodePaint);
      textPainter.text = TextSpan(
        text: memory.title,
        style: TextStyle(fontSize: 10, color: muted),
      );
      textPainter.layout(maxWidth: 120);
      textPainter.paint(canvas, point + const Offset(9, -6));
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) =>
      oldDelegate.memories != memories || oldDelegate.relations != relations;
}
