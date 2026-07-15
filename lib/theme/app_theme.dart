import 'package:flutter/material.dart';

/// Ten period-inspired starting colors. ColorScheme derives complementary and tertiary colors.
const Map<String, Color> themeSeeds = {
  'Dragon red': Color(0xFF8B1E20),
  'Parchment gold': Color(0xFFC28E2B),
  'Dungeon black': Color(0xFF24201C),
  'Arcane blue': Color(0xFF254C7A),
  'Forest green': Color(0xFF385C37),
  'Royal purple': Color(0xFF5D3A78),
  'Copper': Color(0xFF9A4B2A),
  'Teal sigil': Color(0xFF176B6B),
  'Moonstone': Color(0xFF556270),
  'Rose spell': Color(0xFF9A395D),
};

ThemeData buildRpgTheme(String selectedSeed, Brightness brightness) {
  final seed = themeSeeds[selectedSeed] ?? themeSeeds.values.first;
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    contrastLevel: 0.15,
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Georgia'),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: scheme.surface,
      titleTextStyle: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w800,
        color: scheme.onSurface,
        letterSpacing: 0.4,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      filled: true,
      fillColor: scheme.surfaceContainerHighest
          .withValues(alpha: brightness == Brightness.dark ? 0.28 : 0.45),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
      selectedLabelTextStyle: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}
