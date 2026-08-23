import 'package:flutter/material.dart';

/// Ten period-inspired starting colors. ColorScheme derives complementary and tertiary colors.
const Map<String, Color> themeSeeds = {
  'Dragon Red': Color(0xFF8B1E20),
  'Parchment Gold': Color(0xFFC28E2B),
  'Dungeon Black': Color(0xFF24201C),
  'Arcane Blue': Color(0xFF254C7A),
  'Forest Green': Color(0xFF385C37),
  'Royal Purple': Color(0xFF5D3A78),
  'Copper': Color(0xFF9A4B2A),
  'Teal sigil': Color(0xFF176B6B),
  'Greyscale': Color(0xFF666666),
  'Greyscale - High Contrast': Color(0xFFBDBDBD),
};

const String defaultThemeName = 'Arcane Blue';
const String greyscaleThemeName = 'Greyscale';
const String greyscaleHighContrastThemeName = 'Greyscale - High Contrast';
// Kept as aliases for callers compiled against the previous names.
const String highContrastDarkThemeName = greyscaleHighContrastThemeName;
const String colorVisionAccessibleThemeName = greyscaleThemeName;

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
    case 'Color Vision Accessible':
      return greyscaleThemeName;
    case 'High Contrast Dark':
      return greyscaleHighContrastThemeName;
    default:
      return themeSeeds.containsKey(name) ? name : defaultThemeName;
  }
}

ThemeData buildRpgTheme(String selectedSeed, Brightness brightness) {
  final name = canonicalThemeName(selectedSeed);
  final forcedDark =
      name == greyscaleHighContrastThemeName || name == 'Dungeon black';
  final effectiveBrightness = forcedDark ? Brightness.dark : brightness;
  final seed = themeSeeds[name]!;
  var scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: effectiveBrightness,
    contrastLevel: forcedDark ? 1.0 : 0.15,
  );
  if (name == greyscaleThemeName || name == greyscaleHighContrastThemeName) {
    Color grey(Color color) {
      final channel = (color.computeLuminance() * 255).round().clamp(0, 255);
      return Color.fromARGB(255, channel, channel, channel);
    }

    scheme = scheme.copyWith(
      primaryContainer: grey(scheme.primaryContainer),
      onPrimaryContainer: grey(scheme.onPrimaryContainer),
      primaryFixed: grey(scheme.primaryFixed),
      primaryFixedDim: grey(scheme.primaryFixedDim),
      onPrimaryFixed: grey(scheme.onPrimaryFixed),
      onPrimaryFixedVariant: grey(scheme.onPrimaryFixedVariant),
      secondaryContainer: grey(scheme.secondaryContainer),
      onSecondaryContainer: grey(scheme.onSecondaryContainer),
      secondaryFixed: grey(scheme.secondaryFixed),
      secondaryFixedDim: grey(scheme.secondaryFixedDim),
      onSecondaryFixed: grey(scheme.onSecondaryFixed),
      onSecondaryFixedVariant: grey(scheme.onSecondaryFixedVariant),
      tertiary: grey(scheme.tertiary),
      onTertiary: grey(scheme.onTertiary),
      tertiaryContainer: grey(scheme.tertiaryContainer),
      onTertiaryContainer: grey(scheme.onTertiaryContainer),
      tertiaryFixed: grey(scheme.tertiaryFixed),
      tertiaryFixedDim: grey(scheme.tertiaryFixedDim),
      onTertiaryFixed: grey(scheme.onTertiaryFixed),
      onTertiaryFixedVariant: grey(scheme.onTertiaryFixedVariant),
      error: grey(scheme.error),
      onError: grey(scheme.onError),
      errorContainer: grey(scheme.errorContainer),
      onErrorContainer: grey(scheme.onErrorContainer),
      outlineVariant: grey(scheme.outlineVariant),
      surfaceDim: grey(scheme.surfaceDim),
      surfaceTint: grey(scheme.surfaceTint),
      surfaceBright: grey(scheme.surfaceBright),
      surfaceContainerLowest: grey(scheme.surfaceContainerLowest),
      surfaceContainerLow: grey(scheme.surfaceContainerLow),
      surfaceContainer: grey(scheme.surfaceContainer),
      surfaceContainerHigh: grey(scheme.surfaceContainerHigh),
      inverseSurface: grey(scheme.inverseSurface),
      onInverseSurface: grey(scheme.onInverseSurface),
      inversePrimary: grey(scheme.inversePrimary),
      shadow: grey(scheme.shadow),
      scrim: grey(scheme.scrim),
      primary: effectiveBrightness == Brightness.dark
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF303030),
      onPrimary: effectiveBrightness == Brightness.dark
          ? const Color(0xFF000000)
          : const Color(0xFFFFFFFF),
      secondary: effectiveBrightness == Brightness.dark
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF303030),
      onSecondary: effectiveBrightness == Brightness.dark
          ? const Color(0xFF000000)
          : const Color(0xFFFFFFFF),
      surface: effectiveBrightness == Brightness.dark
          ? const Color(0xFF101010)
          : const Color(0xFFF7F7F7),
      onSurface: effectiveBrightness == Brightness.dark
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF111111),
      surfaceContainerHighest: effectiveBrightness == Brightness.dark
          ? const Color(0xFF2A2A2A)
          : const Color(0xFFE6E6E6),
      onSurfaceVariant: effectiveBrightness == Brightness.dark
          ? const Color(0xFFF5F5F5)
          : const Color(0xFF202020),
      outline: effectiveBrightness == Brightness.dark
          ? const Color(0xFFE0E0E0)
          : const Color(0xFF404040),
    );
  }
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
