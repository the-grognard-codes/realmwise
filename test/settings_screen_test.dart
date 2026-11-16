import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:realmwise/screens/settings_screen.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:realmwise/services/catalog_recovery.dart';
import 'package:realmwise/services/export_destination.dart';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/sync/sync_session.dart';
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
  for (final export in [
    (
      tab: 'Database',
      button: 'Export device bundle',
      name: 'realmwise.realmwise',
      mime: 'application/zip',
      success: 'Portable device bundle exported.',
    ),
    (
      tab: 'Database',
      button: 'Export CSV',
      name: 'realmwise_export.csv',
      mime: 'text/csv',
      success: 'Catalog CSV exported.',
    ),
    (
      tab: 'Diagnostics',
      button: 'Generate diagnostic bundle',
      name: 'realmwise-diagnostics.zip',
      mime: 'application/zip',
      success: 'Diagnostic bundle saved.',
    ),
  ]) {
    testWidgets('${export.button} uses the export module and safe feedback', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = PathProviderPlatform.instance;
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('settings_export_'),
      ))!;
      PathProviderPlatform.instance = _FakePathProvider(folder.path);
      SharedPreferences.setMockInitialValues({
        'diagnostic_options_enabled': true,
      });
      final storage = _MemoryTokenStorage();
      final controller = AppController(
        tokenStorage: storage,
        imageRootPathOverride: '${folder.path}/images',
      );
      final adapter = _ExportAdapter();
      final staging = Directory('${folder.path}/staging');
      try {
        await tester.runAsync(() async {
          await staging.create();
          controller.diagnostics.directory = await Directory(
            '${folder.path}/logs',
          ).create();
          await controller.initialize();
          expect(controller.error, isNull);
          await controller.database.databaseHandle.insert('works', {
            'title': 'Exported work',
          });
          await controller.setRpgGeekKey('private-api-key-marker');
          await controller.database.setSetting(
            'rpggeek_api_key',
            'private-api-key-marker',
          );
          await storage.write('drive_token', 'private-token-marker');
          // Simulate a pre-existing unsanitized log: the diagnostic producer
          // must sanitize again when building the exported archive.
          await controller.diagnostics.initialize();
          final logEntry = jsonEncode({
            'timestamp': '2026-01-01T00:00:00Z',
            'severity': 'warning',
            'event': 'sync.failed',
            'session': 'test',
            'fields': {
              'status': 500,
              'token': 'private-token-marker',
              'apiKey': 'private-api-key-marker',
            },
          });
          await File('${folder.path}/logs/diagnostic.log')
              .writeAsString('$logEntry\n');
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SettingsScreen(
                controller: controller,
                exportDestination: ExportDestination(
                  adapter: adapter,
                  temporaryDirectory: () async => staging,
                ),
              ),
            ),
          ),
        );
        await _pumpUntilVisible(tester, find.text('Interface'));
        await _selectTab(tester, export.tab);
        await tester.ensureVisible(find.text(export.button));
        await tester.pumpAndSettle();

        Future<void> tapExport() async {
          await tester.tap(find.text(export.button));
          await tester.pump();
          for (var i = 0; i < 150; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
            final button = tester.widget<ButtonStyleButton>(
              find.ancestor(
                of: find.text(export.button),
                matching: find.byWidgetPredicate(
                  (widget) => widget is ButtonStyleButton,
                ),
              ),
            );
            if (adapter.calls > 0 && button.onPressed != null) return;
          }
          fail('Export did not finish');
        }

        // Cancelling the destination does not run the producer or show feedback.
        await tapExport();
        expect(adapter.fileName, export.name);
        expect(adapter.mimeType, export.mime);
        expect(adapter.savedBytes, isNull);
        expect(find.byType(SnackBar), findsNothing);
        expect(await tester.runAsync(() => staging.list().toList()), isEmpty);

        adapter.cancel = false;
        await tapExport();
        expect(find.text(export.success), findsOneWidget);
        final bytes = adapter.savedBytes!;
        final contents = export.mime == 'text/csv'
            ? utf8.decode(bytes)
            : ZipDecoder()
                  .decodeBytes(bytes)
                  .files
                  .map((file) => latin1.decode(file.content as List<int>))
                  .join('\n');
        expect(contents, isNot(contains('private-api-key-marker')));
        expect(contents, isNot(contains('private-token-marker')));
        if (export.mime == 'text/csv' || export.name == 'realmwise.realmwise') {
          expect(contents, contains('Exported work'));
        } else {
          expect(contents, contains('sync.failed'));
          expect(contents, contains('500'));
          expect(contents, isNot(contains('Exported work')));
        }
        expect(await tester.runAsync(() => staging.list().toList()), isEmpty);
        ScaffoldMessenger.of(tester.element(find.byType(SettingsScreen)))
            .removeCurrentSnackBar();
        await tester.pumpAndSettle();

        adapter.failCopy = true;
        await tapExport();
        expect(find.text(const ExportFailed().message), findsOneWidget);
        expect(find.textContaining('private-token-marker'), findsNothing);
        expect(await tester.runAsync(() => staging.list().toList()), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => controller.database.listCatalogTierSections('gameSystem'),
        );
        await tester.runAsync(controller.closeDatabase);
        controller.dispose();
        var diagnosticsFlushed = false;
        controller.diagnostics.flush().then((_) => diagnosticsFlushed = true);
        for (var i = 0; i < 100 && !diagnosticsFlushed; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(diagnosticsFlushed, isTrue);
        await tester.runAsync(() => folder.delete(recursive: true));
        PathProviderPlatform.instance = previous;
      }
    });
  }
  for (final route in [
    'sync',
    'sync conflict',
    'download',
    'download conflict',
    'remote newer',
    'unknown status',
  ]) {
    final conflict = route.endsWith('conflict');
    final download = route.startsWith('download');
    final restoresCatalog = conflict || download || route == 'remote newer';
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
        route: route,
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
        if (conflict) {
          expect(find.text('Catalogs differ'), findsOneWidget);
          expect(find.text('Upload and replace remote'), findsOneWidget);
          await tester.tap(find.text('Download and replace local'));
          await tester.pump();
        } else if (route == 'remote newer' || download) {
          expect(
            find.text(
              download ? 'Download remote catalog?' : 'Remote catalog is newer',
            ),
            findsOneWidget,
          );
          expect(find.text('Catalogs differ'), findsNothing);
          expect(find.text('Upload and replace remote'), findsNothing);
          await tester.tap(find.text('Download'));
          await tester.pumpAndSettle();
        } else if (route == 'unknown status') {
          expect(find.text('Sync status unavailable'), findsOneWidget);
          expect(find.text('Upload and replace remote'), findsNothing);
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
        }
        final expected = restoresCatalog
            ? 'Downloaded catalog is active, but recovery needs review. Automatic sync is paused.'
            : 'Catalog synced to Google Drive.';
        await _pumpUntilVisible(tester, find.text(expected));
        expect(find.text(expected), findsOneWidget);
        expect(restores, restoresCatalog ? 1 : 0);
        if (restoresCatalog) {
          expect(find.text('Catalog synced to Google Drive.'), findsNothing);
        }
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
    required this.route,
    super.tokenStorage,
    super.imageRootPathOverride,
  });

  final String route;
  static const _revision = SyncRevision('remote');
  static const _conflict = CatalogsDivergedDecision(
    SyncClassification.divergent,
    _revision,
    'local',
  );

  @override
  Future<SyncResult> syncCatalog() async => switch (route) {
    'sync conflict' => _conflict,
    'remote newer' => const RemoteNewerDecision(_revision, 'local'),
    'unknown status' => const StatusUnknownDecision('local'),
    _ => const SyncUploaded('Google Drive'),
  };

  @override
  Future<SyncResult> downloadCatalog() async => route == 'download conflict'
      ? _conflict
      : const DownloadCatalogDecision(_revision, 'local');

  @override
  Future<SyncResult> answerSyncDecision(
    SyncDecision request,
    SyncChoice choice,
  ) async {
    if (request is StatusUnknownDecision) {
      expect(choice, SyncChoice.retry);
      return const SyncUploaded('Google Drive');
    }
    expect(choice, SyncChoice.download);
    return const SyncDownloaded(needsRecoveryReview: true);
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

class _ExportAdapter implements ExportDestinationAdapter {
  bool cancel = true;
  bool failCopy = false;
  int calls = 0;
  String? fileName;
  String? mimeType;
  List<int>? savedBytes;

  @override
  Future<ExportTarget?> chooseDestination({
    required String fileName,
    required String mimeType,
  }) async {
    calls++;
    this.fileName = fileName;
    this.mimeType = mimeType;
    return cancel ? null : _ExportTarget(this);
  }
}

class _ExportTarget extends ExportTarget {
  _ExportTarget(this.adapter);
  final _ExportAdapter adapter;
  @override
  Future<void> save(String temporaryPath) async {
    if (adapter.failCopy) throw StateError('private-token-marker');
    adapter.savedBytes = await File(temporaryPath).readAsBytes();
  }
}
