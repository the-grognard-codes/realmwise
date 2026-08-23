import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/screens/catalog_screen.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppController controller;
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('realmwise_drawer_');
    PathProviderPlatform.instance = _FakePathProvider(folder.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    controller = AppController(tokenStorage: _MemoryTokenStorage());
    await controller.openDatabase(
      '${folder.path}${Platform.pathSeparator}catalog.db',
      remember: false,
    );
    await controller.database.saveRecord(
      const CatalogRecord(
        work: BookWork(
          title: 'Core Rulebook',
          gameSystem: 'RIFTS',
          gameSetting: 'Rifts Earth',
        ),
      ),
    );
  });

  tearDown(() async {
    await controller.closeDatabase();
    controller.dispose();
    await folder.delete(recursive: true);
  });

  Future<void> pumpCatalog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CatalogScreen(controller: controller)),
      ),
    );
    // CatalogScreen performs an asynchronous database read in initState. Use
    // bounded frames here: the app shell can keep an indeterminate progress
    // animation alive, which makes pumpAndSettle wait forever.
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      if (find.byTooltip('Open library').evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.byTooltip('Open library'), findsOneWidget);
  }

  Future<void> pumpInteraction(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  testWidgets('opens the phone drawer and closes from its scrim', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await pumpCatalog(tester);

    await tester.tap(find.byTooltip('Open library'));
    await pumpInteraction(tester);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('RIFTS'), findsOneWidget);

    await tester.tapAt(const Offset(390, 400));
    await pumpInteraction(tester);
    expect(find.text('Library'), findsNothing);
  });

  testWidgets('Android Back and close control dismiss the drawer', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await pumpCatalog(tester);

    await tester.tap(find.byTooltip('Open library'));
    await pumpInteraction(tester);
    await tester.binding.handlePopRoute();
    await pumpInteraction(tester);
    expect(find.text('Library'), findsNothing);

    await tester.tap(find.byTooltip('Open library'));
    await pumpInteraction(tester);
    final close = find.byTooltip('Close library').last;
    await tester.ensureVisible(close);
    await tester.tap(close);
    await pumpInteraction(tester);
    expect(find.text('Library'), findsNothing);
  });

  testWidgets('selecting a leaf closes the drawer', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await pumpCatalog(tester);

    await tester.tap(find.byTooltip('Open library'));
    await pumpInteraction(tester);
    final system = find
        .ancestor(
          of: find.text('RIFTS').last,
          matching: find.byType(ExpansionTile),
        )
        .last;
    await tester.ensureVisible(system);
    await tester.tap(system);
    await pumpInteraction(tester);
    final setting = find
        .ancestor(
          of: find.text('Rifts Earth').last,
          matching: find.byType(ExpansionTile),
        )
        .last;
    await tester.ensureVisible(setting);
    await tester.tap(setting);
    await pumpInteraction(tester);
    final leaf = find
        .ancestor(
          of: find.text('Core Rulebook').last,
          matching: find.byType(ListTile),
        )
        .last;
    await tester.ensureVisible(leaf);
    await tester.tap(leaf);
    await pumpInteraction(tester);
    expect(find.text('Library'), findsNothing);
  });
}
