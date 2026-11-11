import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:realmwise/screens/settings_screen.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:realmwise/services/catalog_recovery.dart';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/services/sync_metadata.dart';
import 'package:realmwise/theme/app_theme.dart';

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
  for (final route in [
    'sync',
    'sync conflict',
    'download',
    'download conflict',
  ]) {
    final conflict = route != 'sync';
    final download = route.startsWith('download');
    testWidgets('sync message handles $route', (tester) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = PathProviderPlatform.instance;
      final folder = await tester.runAsync(
        () => Directory.systemTemp.createTemp('settings_sync_'),
      );
      PathProviderPlatform.instance = _FakePathProvider(folder!.path);
      SharedPreferences.setMockInitialValues({});
      final controller = _SyncMessageController(
        conflict: conflict,
        downloadConflict: route == 'download conflict',
        tokenStorage: _MemoryTokenStorage(),
        imageRootPathOverride: '${folder.path}/images',
      );
      var restores = 0;
      try {
        await tester.runAsync(controller.initialize);
        controller.syncCoordinator.provider = _Provider();
        controller.syncCoordinator.session = const SyncAuthSession(
          accountId: 'account',
        );
        controller.syncCoordinator.metadata = const SyncMetadata(
          catalogIdentity: 'catalog',
          state: SyncState.ready,
        );
        controller.syncMetadata = controller.syncCoordinator.metadata;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SettingsScreen(
                controller: controller,
                onSyncRestore: () => restores++,
              ),
            ),
          ),
        );
        await _pumpUntilVisible(tester, find.text('Cloud Sync'));
        await _selectTab(tester, 'Cloud Sync');
        await tester.ensureVisible(
          find.text(download ? 'Download Remote' : 'Sync Now'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(download ? 'Download Remote' : 'Sync Now'));
        await tester.pumpAndSettle();
        if (download) {
          await tester.tap(find.text('Download'));
          await tester.pumpAndSettle();
        }
        if (route.endsWith('conflict')) {
          await tester.tap(find.text('Download and replace local'));
          await tester.pump();
        }
        final expected = conflict
            ? 'Downloaded catalog is active, but recovery needs review. Automatic sync is paused.'
            : 'Catalog synced to Google Drive.';
        await _pumpUntilVisible(tester, find.text(expected));
        expect(find.text(expected), findsOneWidget);
        expect(restores, conflict ? 1 : 0);
        if (conflict)
          expect(find.text('Catalog synced to Google Drive.'), findsNothing);
        final syncButton = find.ancestor(
          of: find.text('Sync Now'),
          matching: find.byWidgetPredicate((widget) => widget is FilledButton),
        );
        for (
          var i = 0;
          i < 100 && tester.widget<FilledButton>(syncButton).onPressed == null;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(tester.widget<FilledButton>(syncButton).onPressed, isNotNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        // Drain database queries started by the final Settings rebuild.
        await tester.runAsync(
          () => controller.database.listCatalogTierSections('gameSystem'),
        );
        await tester.runAsync(controller.closeDatabase);
        controller.dispose();
        await tester.runAsync(() => folder.delete(recursive: true));
        PathProviderPlatform.instance = previous;
      }
    });
  }
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
        await controller.recovery.snapshot(SnapshotKind.preRestore);
      });
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(controller: controller)),
      );
      await _pumpUntilVisible(tester, find.text('Interface'));

      expect(find.text('Database'), findsOneWidget);
      expect(find.text('Cloud Sync'), findsOneWidget);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('Greyscale'), findsOneWidget);
      expect(find.text('Greyscale - High Contrast'), findsNothing);
      expect(themeSeeds.keys, isNot(contains('Greyscale - High Contrast')));

      final appearanceSelector = find.byType(SegmentedButton<ThemeMode>);
      Finder appearanceOption(String label) =>
          find.descendant(of: appearanceSelector, matching: find.text(label));
      Future<void> selectAppearance(String label, ThemeMode mode) async {
        await tester.ensureVisible(appearanceOption(label));
        await tester.tap(appearanceOption(label));
        await tester.pump();
        for (var i = 0; i < 100; i++) {
          final selector = tester.widget<SegmentedButton<ThemeMode>>(
            appearanceSelector,
          );
          if (controller.themeMode == mode &&
              selector.onSelectionChanged != null) {
            return;
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(controller.themeMode, mode);
      }

      await selectAppearance('Dark', ThemeMode.dark);
      expect(controller.themeMode, ThemeMode.dark);
      await selectAppearance('Light', ThemeMode.light);
      expect(controller.themeMode, ThemeMode.light);
      await selectAppearance('System', ThemeMode.system);
      expect(controller.themeMode, ThemeMode.system);

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
      await _pumpUntilVisible(tester, find.textContaining('Before restore |'));
      expect(find.textContaining('Before restore |'), findsOneWidget);
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

class _Provider implements SyncProvider {
  @override
  String get provider => 'fake';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SyncMessageController extends AppController {
  _SyncMessageController({
    required this.conflict,
    this.downloadConflict = false,
    super.tokenStorage,
    super.imageRootPathOverride,
  });
  final bool conflict;
  final bool downloadConflict;
  CatalogRecoveryWarning? pendingWarning;
  @override
  CatalogRecoveryWarning? get recoveryWarning => pendingWarning;
  @override
  Future<void> syncNow() async {
    if (conflict)
      throw const SyncDecisionRequired(
        SyncClassificationResult(SyncClassification.divergent),
        localFingerprint: 'local',
      );
  }

  @override
  Future<bool> resolveSyncDecision(
    SyncConflictChoice choice, {
    required SyncClassificationResult decision,
    required String localFingerprint,
  }) async {
    expect(choice, SyncConflictChoice.downloadReplaceLocal);
    pendingWarning = const CatalogRecoveryWarning(
      originalPath: 'original.rollback.tmp',
    );
    return true;
  }

  @override
  Future<bool> downloadRemoteBundle({
    SyncRemoteMetadata? expectedRemote,
    String? expectedLocalFingerprint,
    Future<void> Function()? backup,
  }) async {
    if (downloadConflict)
      throw const SyncDecisionRequired(
        SyncClassificationResult(SyncClassification.divergent),
        localFingerprint: 'local',
      );
    pendingWarning = const CatalogRecoveryWarning(
      originalPath: 'original.rollback.tmp',
    );
    return true;
  }
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
