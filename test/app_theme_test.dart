import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/theme/app_theme.dart';

void main() {
  test('theme catalog has Arcane Blue as default and excludes removed themes', () {
    expect(canonicalThemeName(null), defaultThemeName);
    expect(canonicalThemeName('Rose spell'), defaultThemeName);
    expect(canonicalThemeName('Moonstone'), defaultThemeName);
    expect(themeSeeds.keys, contains(defaultThemeName));
    expect(themeSeeds.keys, contains(highContrastDarkThemeName));
    expect(themeSeeds.keys, contains(colorVisionAccessibleThemeName));
    expect(themeSeeds.keys, isNot(contains('Rose spell')));
    expect(themeSeeds.keys, isNot(contains('Moonstone')));
  });

  test('high contrast dark stays dark regardless of requested brightness', () {
    expect(
      buildRpgTheme(highContrastDarkThemeName, Brightness.light).brightness,
      Brightness.dark,
    );
    expect(
      buildRpgTheme(highContrastDarkThemeName, Brightness.dark)
          .colorScheme
          .brightness,
      Brightness.dark,
    );
  });
}
