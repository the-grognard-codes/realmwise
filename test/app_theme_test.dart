import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/theme/app_theme.dart';

int channelValue(double channel) => (channel * 255.0).round().clamp(0, 255);

void main() {
  test(
    'theme catalog has Arcane Blue as default and excludes removed themes',
    () {
      expect(canonicalThemeName(null), defaultThemeName);
      expect(canonicalThemeName('Rose spell'), defaultThemeName);
      expect(canonicalThemeName('Moonstone'), defaultThemeName);
      expect(themeSeeds.keys, contains(defaultThemeName));
      expect(themeSeeds.keys, contains(greyscaleHighContrastThemeName));
      expect(themeSeeds.keys, contains(greyscaleThemeName));
      expect(
        canonicalThemeName('High Contrast Dark'),
        greyscaleHighContrastThemeName,
      );
      expect(canonicalThemeName('Color Vision Accessible'), greyscaleThemeName);
      expect(themeSeeds.keys, isNot(contains('Rose spell')));
      expect(themeSeeds.keys, isNot(contains('Moonstone')));
      expect(themeSeeds.keys, isNot(contains('Copper')));
      expect(canonicalThemeName('Copper'), defaultThemeName);
      expect(canonicalThemeName('Teal sigil'), 'Teal Sigil');
      expect(themeSeeds.keys, contains('Teal Sigil'));
    },
  );

  test('legacy high contrast names migrate to greyscale and honor brightness', () {
    expect(
      buildRpgTheme(
        'Greyscale - High Contrast',
        Brightness.light,
      ).brightness,
      Brightness.light,
    );
    expect(
      buildRpgTheme(
        greyscaleHighContrastThemeName,
        Brightness.dark,
      ).colorScheme.brightness,
      Brightness.dark,
    );
  });

  test('Dungeon black supports both brightness modes and uses a flagstone palette', () {
    expect(
      buildRpgTheme('Dungeon black', Brightness.light).brightness,
      Brightness.light,
    );
    expect(
      buildRpgTheme('Dungeon black', Brightness.dark).brightness,
      Brightness.dark,
    );
    expect(
      buildRpgTheme('Dungeon black', Brightness.light).colorScheme.surface,
      isNot(buildRpgTheme('Dungeon black', Brightness.dark).colorScheme.surface),
    );
    final dungeon = buildRpgTheme(
      'Dungeon black',
      Brightness.dark,
    ).colorScheme;
    final parchment = buildRpgTheme(
      'Parchment gold',
      Brightness.light,
    ).colorScheme;
    expect(dungeon.surface, isNot(parchment.surface));
    expect(dungeon.primary, isNot(parchment.primary));
    expect(channelValue(dungeon.surface.r), lessThan(40));
    expect(channelValue(dungeon.surface.g), lessThan(40));
    expect(channelValue(dungeon.surface.b), lessThan(40));
    expect(
      channelValue(dungeon.primary.g),
      greaterThan(channelValue(dungeon.primary.r)),
    );
    expect(
      channelValue(dungeon.primary.r),
      greaterThan(channelValue(dungeon.primary.b)),
    );
    expect(
      channelValue(dungeon.secondary.r),
      greaterThan(channelValue(dungeon.secondary.g)),
    );
    expect(
      channelValue(dungeon.secondary.g),
      greaterThan(channelValue(dungeon.secondary.b)),
    );
    expect(
      channelValue(dungeon.tertiary.r),
      greaterThan(channelValue(dungeon.tertiary.b)),
    );
    expect(
      channelValue(dungeon.tertiary.g),
      greaterThan(channelValue(dungeon.tertiary.r)),
    );
  });

  test('named palettes preserve hues and readable contrast', () {
    final dragon = buildRpgTheme('Dragon Red', Brightness.light).colorScheme;
    final parchment = buildRpgTheme(
      'Parchment Gold',
      Brightness.light,
    ).colorScheme;
    final forest = buildRpgTheme('Forest Green', Brightness.light).colorScheme;
    expect(
      channelValue(dragon.primary.r),
      greaterThan(channelValue(dragon.primary.g)),
    );
    expect(
      channelValue(parchment.surface.r),
      greaterThan(channelValue(parchment.surface.b)),
    );
    expect(
      channelValue(parchment.tertiary.r),
      greaterThan(channelValue(parchment.tertiary.g)),
    );
    expect(
      channelValue(forest.primary.g),
      greaterThan(channelValue(forest.primary.r)),
    );
    expect(
      channelValue(forest.secondary.r),
      greaterThan(channelValue(forest.secondary.b)),
    );
    expect(
      channelValue(forest.tertiary.r),
      greaterThan(channelValue(forest.tertiary.b)),
    );
    expect(dragon.primary, isNot(parchment.primary));
    expect(forest.primary, isNot(dragon.primary));
    expect(dragon.primary, const Color(0xFF8F1D2C));
    expect(parchment.surface, const Color(0xFFF5EBD3));
    expect(forest.secondary, const Color(0xFF7A4D2D));
    double contrast(Color a, Color b) {
      final hi = a.computeLuminance() > b.computeLuminance() ? a : b;
      final lo = identical(hi, a) ? b : a;
      return (hi.computeLuminance() + .05) / (lo.computeLuminance() + .05);
    }

    expect(
      contrast(dragon.primary, dragon.onPrimary),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrast(parchment.surface, parchment.onSurface),
      greaterThanOrEqualTo(7),
    );
    expect(contrast(forest.surface, forest.onSurface), greaterThanOrEqualTo(7));
  });

  test('parchment and forest accents are consumed by common components', () {
    for (final name in [
      'Parchment Gold',
      'Forest Green',
      'Royal Purple',
      'Teal Sigil',
    ]) {
      final theme = buildRpgTheme(name, Brightness.light);
      expect(
        theme.navigationBarTheme.indicatorColor,
        theme.colorScheme.tertiaryContainer,
      );
      expect(
        theme.chipTheme.selectedColor,
        theme.colorScheme.tertiaryContainer,
      );
      final outline = theme.outlinedButtonTheme.style?.side?.resolve({});
      expect(outline?.color, theme.colorScheme.tertiary);
    }
    final dragon = buildRpgTheme('Dragon Red', Brightness.light);
    expect(
      dragon.navigationBarTheme.indicatorColor,
      dragon.colorScheme.primaryContainer,
    );
    expect(
      buildRpgTheme('Royal Purple', Brightness.light).colorScheme.primary,
      const Color(0xFF5D3678),
    );
    expect(
      buildRpgTheme('Teal Sigil', Brightness.light).colorScheme.surface,
      const Color(0xFFF0FAF9),
    );
  });

  test('greyscale theme colors are neutral', () {
    final schemes = [
      buildRpgTheme(greyscaleThemeName, Brightness.light).colorScheme,
      buildRpgTheme(
        greyscaleHighContrastThemeName,
        Brightness.dark,
      ).colorScheme,
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
        expect(channelValue(color.r), channelValue(color.g));
        expect(channelValue(color.g), channelValue(color.b));
      }
    }
  });

  test('high contrast greyscale surface text meets AAA contrast', () {
    final scheme = buildRpgTheme(
      greyscaleHighContrastThemeName,
      Brightness.light,
    ).colorScheme;
    final lighter =
        scheme.surface.computeLuminance() > scheme.onSurface.computeLuminance();
    final high = lighter ? scheme.surface : scheme.onSurface;
    final low = lighter ? scheme.onSurface : scheme.surface;
    final ratio =
        (high.computeLuminance() + 0.05) / (low.computeLuminance() + 0.05);
    expect(ratio, greaterThanOrEqualTo(7));
  });
}
