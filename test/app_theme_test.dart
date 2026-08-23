import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/theme/app_theme.dart';

void main() {
  test('theme catalog has Arcane Blue as default and excludes removed themes', () {
    expect(canonicalThemeName(null), defaultThemeName);
    expect(canonicalThemeName('Rose spell'), defaultThemeName);
    expect(canonicalThemeName('Moonstone'), defaultThemeName);
    expect(themeSeeds.keys, contains(defaultThemeName));
    expect(themeSeeds.keys, contains(greyscaleHighContrastThemeName));
    expect(themeSeeds.keys, contains(greyscaleThemeName));
    expect(canonicalThemeName('High Contrast Dark'), greyscaleHighContrastThemeName);
    expect(canonicalThemeName('Color Vision Accessible'), greyscaleThemeName);
    expect(themeSeeds.keys, isNot(contains('Rose spell')));
    expect(themeSeeds.keys, isNot(contains('Moonstone')));
  });

  test('high contrast dark stays dark regardless of requested brightness', () {
    expect(
      buildRpgTheme(greyscaleHighContrastThemeName, Brightness.light).brightness,
      Brightness.dark,
    );
    expect(
      buildRpgTheme(greyscaleHighContrastThemeName, Brightness.dark)
          .colorScheme
          .brightness,
      Brightness.dark,
    );
  });

  test('Dungeon black stays dark and has its own palette', () {
    expect(
      buildRpgTheme('Dungeon black', Brightness.light).brightness,
      Brightness.dark,
    );
    expect(
      buildRpgTheme('Dungeon black', Brightness.dark).brightness,
      Brightness.dark,
    );
    final dungeon = buildRpgTheme('Dungeon black', Brightness.light).colorScheme;
    final parchment = buildRpgTheme('Parchment gold', Brightness.light).colorScheme;
    expect(dungeon.surface, isNot(parchment.surface));
    expect(dungeon.primary, isNot(parchment.primary));
  });

  test('greyscale theme colors are neutral', () {
    final schemes = [
      buildRpgTheme(greyscaleThemeName, Brightness.light).colorScheme,
      buildRpgTheme(greyscaleHighContrastThemeName, Brightness.dark).colorScheme,
    ];
    for (final scheme in schemes) {
      final colors = [
        scheme.primary,
        scheme.onPrimary,
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        scheme.primaryFixed,
        scheme.primaryFixedDim,
        scheme.onPrimaryFixed,
        scheme.onPrimaryFixedVariant,
        scheme.secondary,
        scheme.onSecondary,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        scheme.secondaryFixed,
        scheme.secondaryFixedDim,
        scheme.onSecondaryFixed,
        scheme.onSecondaryFixedVariant,
        scheme.tertiary,
        scheme.onTertiary,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        scheme.tertiaryFixed,
        scheme.tertiaryFixedDim,
        scheme.onTertiaryFixed,
        scheme.onTertiaryFixedVariant,
        scheme.error,
        scheme.onError,
        scheme.errorContainer,
        scheme.onErrorContainer,
        scheme.surface,
        scheme.onSurface,
        scheme.surfaceDim,
        scheme.surfaceBright,
        scheme.surfaceTint,
        scheme.surfaceContainerLowest,
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        scheme.outline,
        scheme.outlineVariant,
        scheme.inverseSurface,
        scheme.onInverseSurface,
        scheme.inversePrimary,
        scheme.shadow,
        scheme.scrim,
      ];
      for (final color in colors) {
        expect(color.red, color.green);
        expect(color.green, color.blue);
      }
    }
  });

  test('high contrast greyscale surface text meets AAA contrast', () {
    final scheme = buildRpgTheme(
      greyscaleHighContrastThemeName,
      Brightness.light,
    ).colorScheme;
    final lighter = scheme.surface.computeLuminance() >
        scheme.onSurface.computeLuminance();
    final high = lighter ? scheme.surface : scheme.onSurface;
    final low = lighter ? scheme.onSurface : scheme.surface;
    final ratio = (high.computeLuminance() + 0.05) /
        (low.computeLuminance() + 0.05);
    expect(ratio, greaterThanOrEqualTo(7));
  });
}
