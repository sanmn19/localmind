import 'package:flutter/material.dart';

class AppColors {
  // Dark Theme — DESIGN.md tokens
  static const Color darkBackground = Color(0xFF212121); // surface-main
  static const Color darkSurface = Color(0xFF171717); // surface-sidebar
  static const Color darkSurfaceInput = Color(0xFF2F2F2F); // surface-input
  static const Color darkSurfaceCard = Color(0xFF2F2F2F); // surface-card
  static const Color darkBorder = Color(0xFF424242); // border-subtle
  static const Color darkPrimaryText = Color(0xFFECECEC); // text-primary
  static const Color darkMutedText = Color(0xFFB4B4B4); // text-muted
  static const Color darkAccent = Colors.white; // primary (OpenAI green)

  // Light Theme
  static const Color lightBackground = Color(0xFFFAFAFA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFE5E5E5);
  static const Color lightPrimaryText = Color(0xFF0A0A0A);
  static const Color lightMutedText = Color(0xFF71717A);
  static const Color lightAccent = Colors.black; // primary (OpenAI green)

  // Claude Theme
  static const Color claudeBackground = Color(0xFFF5F4ED);
  static const Color claudeSurface = Color(0xFFFAF9F5);
  static const Color claudeBorder = Color(0xFFF0EEE6);
  static const Color claudePrimaryText = Color(0xFF141413);
  static const Color claudeSecondaryText = Color(0xFF5E5D59);
  static const Color claudeMutedText = Color(0xFF87867F);
  static const Color claudeAccent =
      Colors.deepOrangeAccent; // primary (OpenAI green)

  // Claude Dark Theme
  static const Color claudeDarkBackground = Color(0xFF141413);
  static const Color claudeDarkSurface = Color(0xFF30302E);
  static const Color claudeDarkBorder = Color(0xFF30302E);
  static const Color claudeDarkPrimaryText = Color(0xFFFAF9F5);
  static const Color claudeDarkSecondaryText = Color(0xFFB0AEA5);

  static const Color success = Color(0xFF22C55E);
  static const Color error = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);

  // Selection-fork highlight (selection-fork-chats): a pale amber
  // "highlighter" streak in light mode. In dark mode the band becomes a
  // low-alpha amber wash so the overlaid markdown keeps the surface text
  // colors, and the fallback chip swaps to the house warning amber.
  static const Color lightForkHighlight = Color(0xFFFEF3C7);
  static const Color darkForkHighlight = Color(0x29FEF3C7);
  static const Color lightForkChip = Color(0xFFFEF3C7);
  static const Color darkForkChip = warning;
}
