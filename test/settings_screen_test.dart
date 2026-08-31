import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:realmwise/screens/settings_screen.dart';
import 'package:realmwise/services/app_controller.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _MemoryTokenStorage implements TokenStorage {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('missing backup modification time is safe', () {
    expect(backupLastModifiedForSettings(File('missing-backup.db')), isNull);
  });

  testWidgets('settings are grouped into local and cloud sync tabs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previousPathProvider = PathProviderPlatform.instance;
    Directory? folder;
    late final AppController controller;
    var controllerCreated = false;
    var initialized = false;
    try {
      await tester.runAsync(() async {
        folder = await Directory.systemTemp.createTemp('realmwise_settings_');
        PathProviderPlatform.instance = _FakePathProvider(folder!.path);
        SharedPreferences.setMockInitialValues(<String, Object>{});
        controller = AppController(
          tokenStorage: _MemoryTokenStorage(),
          imageRootPathOverride:
              '${folder!.path}${Platform.pathSeparator}images',
        );
        controllerCreated = true;
        await controller.initialize();
        initialized = true;
      });
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(controller: controller)),
      );
      await _pumpUntilVisible(tester, find.text('Interface'));

      expect(find.text('Database'), findsOneWidget);
      expect(find.text('Cloud Sync'), findsOneWidget);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Custom Catalog Icons'), findsOneWidget);
      await _selectTab(tester, 'Sources');
      expect(find.text('RPGGeek Data Enrichment'), findsOneWidget);
      expect(find.text('Open Library'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Email Address'), findsOneWidget);
      expect(find.textContaining('501(c)(3)'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Open RPGGeek API application page'), findsOneWidget);
      expect(find.textContaining('product and series details'), findsOneWidget);
      await _selectTab(tester, 'Database');
      expect(find.text('Local Image Library'), findsOneWidget);
      expect(find.text('Manual Device Sync'), findsOneWidget);
      expect(find.text('Database and Recovery'), findsOneWidget);
      expect(find.text('Sync Status'), findsNothing);

      await _selectTab(tester, 'Cloud Sync');
      expect(find.text('Sync Status'), findsOneWidget);
      expect(find.text('Automatic sync'), findsWidgets);
      expect(find.textContaining('Device ID:'), findsOneWidget);
      expect(find.textContaining('single-device backup'), findsOneWidget);
      expect(find.text('Sync Providers'), findsOneWidget);
      expect(find.text('Sync Information'), findsOneWidget);
      expect(
        find.text('Include uploaded images and catalog icons'),
        findsOneWidget,
      );
      expect(find.textContaining('isolated Realmwise section'), findsOneWidget);
      expect(find.textContaining('Destination:'), findsNothing);

      await tester.runAsync(controller.closeDatabase);
      await tester.pump();
      await _selectTab(tester, 'Interface');

      expect(
        find.text('Catalog icons will be available when the database is open.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      if (initialized && controller.isOpen) {
        await tester.runAsync(controller.closeDatabase);
      }
      if (controllerCreated) controller.dispose();
      final fixtureFolder = folder;
      if (fixtureFolder != null) {
        await tester.runAsync(() => fixtureFolder.delete(recursive: true));
      }
      PathProviderPlatform.instance = previousPathProvider;
    }
  });
}

Future<void> _pumpUntilVisible(WidgetTester tester, Finder finder) async {
  await tester.pump();
  for (var i = 0; i < 100; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  expect(finder, findsOneWidget);
}

Future<void> _selectTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
