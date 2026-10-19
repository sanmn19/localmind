import 'package:flutter/material.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/theme/colors.dart';
import 'package:localmind/l10n/app_localizations.dart';

/// The availability chip shown on a [ModelTile] for models that are not usable
/// right now. Renders nothing for [ModelAvailability.available].
class ModelAvailabilityBadge extends StatelessWidget {
  const ModelAvailabilityBadge({
    super.key,
    required this.availability,
    required this.isDark,
  });

  final ModelAvailability availability;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = switch (availability) {
      ModelAvailability.available => null,
      ModelAvailability.loadable => l10n.model_availability_loadable,
      ModelAvailability.unavailable => l10n.model_availability_unavailable,
      ModelAvailability.unknown => l10n.model_availability_unknown,
    };
    if (label == null) return const SizedBox.shrink();
    final muted = isDark ? AppColors.darkMutedText : AppColors.lightMutedText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: muted.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: muted)),
    );
  }
}
