import 'package:flutter/material.dart';

/// Ten period-inspired starting colors. ColorScheme derives complementary and tertiary colors.
const Map<String, Color> themeSeeds = {
  'Dragon red': Color(0xFF8B1E20),
  'Parchment gold': Color(0xFFC28E2B),
  'Dungeon black': Color(0xFF24201C),
  'Arcane Blue': Color(0xFF254C7A),
  'Forest green': Color(0xFF385C37),
  'Royal purple': Color(0xFF5D3A78),
  'Copper': Color(0xFF9A4B2A),
  'Teal sigil': Color(0xFF176B6B),
  'High Contrast Dark': Color(0xFF000000),
  'Color Vision Accessible': Color(0xFF0072B2),
};

const String defaultThemeName = 'Arcane Blue';
const String highContrastDarkThemeName = 'High Contrast Dark';
const String colorVisionAccessibleThemeName = 'Color Vision Accessible';

/// Converts names from older releases to the current catalog. Removed themes
/// intentionally fall back to Arcane Blue instead of silently changing to an
/// unrelated palette.
String canonicalThemeName(String? name) {
  switch (name) {
    case 'Arcane blue':
      return defaultThemeName;
    case 'Rose spell':
    case 'Moonstone':
    case null:
      return defaultThemeName;
    default:
      return themeSeeds.containsKey(name) ? name : defaultThemeName;
  }
}

ThemeData buildRpgTheme(String selectedSeed, Brightness brightness) {
  final name = canonicalThemeName(selectedSeed);
  final forcedDark = name == highContrastDarkThemeName;
  final effectiveBrightness = forcedDark ? Brightness.dark : brightness;
  final seed = themeSeeds[name]!;
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: effectiveBrightness,
    contrastLevel: forcedDark ? 1.0 : 0.15,
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: effectiveBrightness,
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
          .withValues(alpha: effectiveBrightness == Brightness.dark ? 0.28 : 0.45),
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
