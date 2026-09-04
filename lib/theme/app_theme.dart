import 'package:flutter/material.dart';

/// Ten period-inspired starting colors. ColorScheme derives complementary and tertiary colors.
const Map<String, Color> themeSeeds = {
  'Dragon Red': Color(0xFF8B1E20),
  'Parchment Gold': Color(0xFFC28E2B),
  'Dungeon Black': Color(0xFF24201C),
  'Arcane Blue': Color(0xFF254C7A),
  'Forest Green': Color(0xFF385C37),
  'Royal Purple': Color(0xFF5D3A78),
  'Teal Sigil': Color(0xFF176B6B),
  'Greyscale': Color(0xFF666666),
};

const String defaultThemeName = 'Arcane Blue';
const String dungeonBlackThemeName = 'Dungeon Black';
const String greyscaleThemeName = 'Greyscale';
// Deprecated aliases retained for source compatibility. The former high
// contrast catalog entry is now canonicalized to the single Greyscale theme.
const String greyscaleHighContrastThemeName = greyscaleThemeName;
const String highContrastDarkThemeName = greyscaleThemeName;
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
    case 'Greyscale - High Contrast':
      return greyscaleThemeName;
    case 'Dungeon black':
      return dungeonBlackThemeName;
    case 'Teal sigil':
      return 'Teal Sigil';
    default:
      return themeSeeds.containsKey(name) ? name : defaultThemeName;
  }
}

ThemeData buildRpgTheme(String selectedSeed, Brightness brightness) {
  final name = canonicalThemeName(selectedSeed);
  final effectiveBrightness = brightness;

  ColorScheme scheme;
  if (name == dungeonBlackThemeName) {
    scheme = ColorScheme.fromSeed(
      seedColor: themeSeeds[name]!,
      brightness: brightness,
      contrastLevel: 0.15,
    );
    if (brightness == Brightness.dark) {
      scheme = scheme.copyWith(
        primary: const Color(0xFF6E7F61),
        onPrimary: const Color(0xFFF8F6EF),
        primaryContainer: const Color(0xFF394236),
        onPrimaryContainer: const Color(0xFFE2E9D7),
        secondary: const Color(0xFF8E6C4A),
        onSecondary: const Color(0xFFF9F3EA),
        secondaryContainer: const Color(0xFF4A3827),
        onSecondaryContainer: const Color(0xFFFFE9D3),
        tertiary: const Color(0xFF7F8468),
        onTertiary: const Color(0xFFF6F4E8),
        tertiaryContainer: const Color(0xFF3C4032),
        onTertiaryContainer: const Color(0xFFE7E8DA),
        surface: const Color(0xFF1C1D1A),
        onSurface: const Color(0xFFF1EFE5),
        surfaceContainerHighest: const Color(0xFF333530),
        surfaceContainerHigh: const Color(0xFF2A2C27),
        surfaceContainer: const Color(0xFF232520),
        surfaceContainerLow: const Color(0xFF1A1C17),
        surfaceContainerLowest: const Color(0xFF11120F),
        onSurfaceVariant: const Color(0xFFD1CFC0),
        outline: const Color(0xFF9A9B8C),
        outlineVariant: const Color(0xFF626458),
        inverseSurface: const Color(0xFFEAE7DB),
        onInverseSurface: const Color(0xFF161713),
        inversePrimary: const Color(0xFF59664E),
        scrim: const Color(0xFF000000),
        shadow: const Color(0xFF000000),
        surfaceDim: const Color(0xFF151712),
        surfaceBright: const Color(0xFF3D3F39),
        surfaceTint: const Color(0xFF758468),
      );
    } else {
      scheme = scheme.copyWith(
        primary: const Color(0xFF4E6145),
        onPrimary: const Color(0xFFFFFFFF),
        primaryContainer: const Color(0xFFDCE8D1),
        onPrimaryContainer: const Color(0xFF10200D),
        secondary: const Color(0xFF765334),
        onSecondary: const Color(0xFFFFFFFF),
        secondaryContainer: const Color(0xFFF1DDC8),
        onSecondaryContainer: const Color(0xFF29170B),
        tertiary: const Color(0xFF566040),
        onTertiary: const Color(0xFFFFFFFF),
        tertiaryContainer: const Color(0xFFE0E5C9),
        onTertiaryContainer: const Color(0xFF171D08),
        surface: const Color(0xFFF5F6EE),
        onSurface: const Color(0xFF181A15),
        surfaceContainerHighest: const Color(0xFFE1E4D9),
        onSurfaceVariant: const Color(0xFF45483F),
        outline: const Color(0xFF74786B),
      );
    }
  } else {
    final seed = themeSeeds[name]!;
    scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: effectiveBrightness,
      contrastLevel: 0.15,
    );
  }

  if (name == greyscaleThemeName) {
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
  final dark = effectiveBrightness == Brightness.dark;
  if (name == 'Dragon Red') {
    scheme = scheme.copyWith(
      primary: dark ? const Color(0xFFD85A67) : const Color(0xFF8F1D2C),
      onPrimary: dark ? const Color(0xFF241014) : const Color(0xFFFFFFFF),
      primaryContainer: dark
          ? const Color(0xFF68232F)
          : const Color(0xFFFFDADF),
      onPrimaryContainer: dark
          ? const Color(0xFFFFDADF)
          : const Color(0xFF3B0710),
      secondary: dark ? const Color(0xFFD7B85A) : const Color(0xFF8A6A20),
      onSecondary: dark ? const Color(0xFF241C08) : const Color(0xFFFFFFFF),
      secondaryContainer: dark
          ? const Color(0xFF564515)
          : const Color(0xFFFFE9A8),
      onSecondaryContainer: dark
          ? const Color(0xFFFFE9A8)
          : const Color(0xFF261B00),
      surface: dark ? const Color(0xFF1E1710) : const Color(0xFFFFF8E8),
      onSurface: dark ? const Color(0xFFFFF5E0) : const Color(0xFF211A12),
      tertiary: dark ? const Color(0xFFF3E6C8) : const Color(0xFF6A552B),
      onTertiary: dark ? const Color(0xFF241C08) : const Color(0xFFFFFFFF),
    );
  } else if (name == 'Parchment Gold') {
    scheme = scheme.copyWith(
      primary: dark ? const Color(0xFFD8BA78) : const Color(0xFFA98A52),
      onPrimary: const Color(0xFF1D180E),
      primaryContainer: dark
          ? const Color(0xFF5B4C2D)
          : const Color(0xFFF1E1B8),
      onPrimaryContainer: dark
          ? const Color(0xFFFFF2CE)
          : const Color(0xFF281F0A),
      surface: dark ? const Color(0xFF211E17) : const Color(0xFFF5EBD3),
      onSurface: dark ? const Color(0xFFFFF4D8) : const Color(0xFF1B1811),
      outline: dark ? const Color(0xFFD8C99E) : const Color(0xFF4B4332),
      tertiary: dark ? const Color(0xFFE06A5F) : const Color(0xFF9C2F2A),
      onTertiary: dark ? const Color(0xFF330B08) : const Color(0xFFFFFFFF),
      tertiaryContainer: dark
          ? const Color(0xFF6B2925)
          : const Color(0xFFFFDAD5),
      onTertiaryContainer: dark
          ? const Color(0xFFFFDAD5)
          : const Color(0xFF3B0805),
      error: dark ? const Color(0xFFFF8A80) : const Color(0xFF9C2F2A),
      onError: dark ? const Color(0xFF3B0907) : const Color(0xFFFFFFFF),
    );
  } else if (name == 'Forest Green') {
    scheme = scheme.copyWith(
      primary: dark ? const Color(0xFF6FA77A) : const Color(0xFF2E5D3B),
      onPrimary: dark ? const Color(0xFF0B2110) : const Color(0xFFFFFFFF),
      primaryContainer: dark
          ? const Color(0xFF244C30)
          : const Color(0xFFC5E8C9),
      onPrimaryContainer: dark
          ? const Color(0xFFD8F5D9)
          : const Color(0xFF0B2110),
      secondary: dark ? const Color(0xFFC18B5E) : const Color(0xFF7A4D2D),
      onSecondary: dark ? const Color(0xFF29170B) : const Color(0xFFFFFFFF),
      secondaryContainer: dark
          ? const Color(0xFF5C3B24)
          : const Color(0xFFEFD0B2),
      onSecondaryContainer: dark
          ? const Color(0xFFFFDCC2)
          : const Color(0xFF29170B),
      tertiary: dark ? const Color(0xFFE2C266) : const Color(0xFFB68D31),
      onTertiary: dark ? const Color(0xFF2A2108) : const Color(0xFFFFFFFF),
      tertiaryContainer: dark
          ? const Color(0xFF66531C)
          : const Color(0xFFFFE6A3),
      onTertiaryContainer: dark
          ? const Color(0xFFFFE6A3)
          : const Color(0xFF241A00),
      surface: dark ? const Color(0xFF121B14) : const Color(0xFFF0F5EC),
      onSurface: dark ? const Color(0xFFE8F2E5) : const Color(0xFF142016),
    );
  } else if (name == 'Royal Purple') {
    scheme = scheme.copyWith(
      primary: dark ? const Color(0xFFB58AD1) : const Color(0xFF5D3678),
      onPrimary: dark ? const Color(0xFF261333) : const Color(0xFFFFFFFF),
      primaryContainer: dark
          ? const Color(0xFF4C2A62)
          : const Color(0xFFEEDBFA),
      onPrimaryContainer: dark
          ? const Color(0xFFF4DFFF)
          : const Color(0xFF24102F),
      secondary: dark ? const Color(0xFFE0B957) : const Color(0xFF916D1F),
      onSecondary: dark ? const Color(0xFF281B03) : const Color(0xFFFFFFFF),
      secondaryContainer: dark
          ? const Color(0xFF594514)
          : const Color(0xFFFFE8A3),
      onSecondaryContainer: dark
          ? const Color(0xFFFFE9A8)
          : const Color(0xFF281B03),
      surface: dark ? const Color(0xFF1D1423) : const Color(0xFFFAF4FC),
      onSurface: dark ? const Color(0xFFF4EAF7) : const Color(0xFF211526),
      tertiary: dark ? const Color(0xFFE0B957) : const Color(0xFF916D1F),
      onTertiary: dark ? const Color(0xFF281B03) : const Color(0xFFFFFFFF),
      tertiaryContainer: dark
          ? const Color(0xFF594514)
          : const Color(0xFFFFE8A3),
      onTertiaryContainer: dark
          ? const Color(0xFFFFE9A8)
          : const Color(0xFF281B03),
    );
  } else if (name == 'Teal Sigil') {
    scheme = scheme.copyWith(
      primary: dark ? const Color(0xFF62D8D1) : const Color(0xFF006E6A),
      onPrimary: dark ? const Color(0xFF003735) : const Color(0xFFFFFFFF),
      primaryContainer: dark
          ? const Color(0xFF005451)
          : const Color(0xFF9DF2EB),
      onPrimaryContainer: dark
          ? const Color(0xFF9DF2EB)
          : const Color(0xFF00201F),
      secondary: dark ? const Color(0xFF8AE6DF) : const Color(0xFF007A75),
      onSecondary: dark ? const Color(0xFF003735) : const Color(0xFFFFFFFF),
      secondaryContainer: dark
          ? const Color(0xFF00615D)
          : const Color(0xFFB5F4EE),
      onSecondaryContainer: dark
          ? const Color(0xFFB5F4EE)
          : const Color(0xFF00201F),
      surface: dark ? const Color(0xFF071C1C) : const Color(0xFFF0FAF9),
      onSurface: dark ? const Color(0xFFE0F7F5) : const Color(0xFF0B1F1F),
      tertiary: dark ? const Color(0xFF8AE6DF) : const Color(0xFF007A75),
      onTertiary: dark ? const Color(0xFF003735) : const Color(0xFFFFFFFF),
      tertiaryContainer: dark
          ? const Color(0xFF00615D)
          : const Color(0xFFB5F4EE),
      onTertiaryContainer: dark
          ? const Color(0xFFB5F4EE)
          : const Color(0xFF00201F),
    );
  }
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: effectiveBrightness,
  );
  final accentTheme = const {
    'Parchment Gold',
    'Forest Green',
    'Royal Purple',
    'Teal Sigil',
  }.contains(name);
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
      fillColor: scheme.surfaceContainerHighest.withValues(
        alpha: effectiveBrightness == Brightness.dark ? 0.28 : 0.45,
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      selectedIconTheme: IconThemeData(
        color: accentTheme
            ? scheme.onTertiaryContainer
            : scheme.onPrimaryContainer,
      ),
      selectedLabelTextStyle: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.bold,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: accentTheme
          ? scheme.tertiaryContainer
          : scheme.primaryContainer,
      indicatorShape: const StadiumBorder(),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          color: accentTheme
              ? scheme.onTertiaryContainer
              : scheme.onPrimaryContainer,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      selectedColor: accentTheme
          ? scheme.tertiaryContainer
          : scheme.primaryContainer,
      labelStyle: TextStyle(
        color: accentTheme
            ? scheme.onTertiaryContainer
            : scheme.onPrimaryContainer,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accentTheme ? scheme.tertiary : scheme.primary,
        side: BorderSide(color: accentTheme ? scheme.tertiary : scheme.outline),
      ),
    ),
  );
}
