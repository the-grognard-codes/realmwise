import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:realmwise/app.dart';
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
    await controller.database.saveRecord(
      const CatalogRecord(
        work: BookWork(
          title: 'Bestiary',
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

  Future<void> pumpInteraction(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpCatalogShell(
    WidgetTester tester, {
    required bool wide,
  }) async {
    await tester.pumpWidget(
      MaterialApp(home: CatalogShell(controller: controller)),
    );
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      final navigation = wide
          ? find.byType(NavigationRail)
          : find.byType(NavigationBar);
      if (navigation.evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    fail('Catalog shell navigation did not appear');
  }

  Finder catalogHeaderIconButton(String tooltip) => find.ancestor(
    of: find.byTooltip(tooltip),
    matching: find.byType(IconButton),
  );

  testWidgets('opens the phone drawer and closes from its scrim', (
    tester,
  ) async {
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

  testWidgets('Android Back and close control dismiss the drawer', (
    tester,
  ) async {
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
        .ancestor(of: find.text('RIFTS').last, matching: find.byType(ListTile))
        .last;
    await tester.ensureVisible(system);
    await tester.tap(system);
    await pumpInteraction(tester);
    expect(find.text('Rifts Earth'), findsOneWidget);
    final setting = find
        .ancestor(
          of: find.text('Rifts Earth').last,
          matching: find.byType(ListTile),
        )
        .last;
    await tester.ensureVisible(setting);
    await tester.tap(setting);
    await pumpInteraction(tester);
    expect(find.text('Core Rulebook'), findsWidgets);
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

  testWidgets('phone shell keeps bottom navigation without a top app bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await pumpCatalogShell(tester, wide: false);

    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('phone catalog content clears the status-bar inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 32);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    await pumpCatalogShell(tester, wide: false);

    final menu = find.byTooltip('Open library');
    expect(tester.getTopLeft(menu).dy, greaterThanOrEqualTo(32));
    await tester.tap(menu);
    await pumpInteraction(tester);
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets(
    'wide shell keeps navigation rail without a bottom navigation bar',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await pumpCatalogShell(tester, wide: true);

      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    },
  );

  testWidgets('search toggles the hidden catalog filters and header controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await pumpCatalog(tester);

    expect(find.text('Filter catalog text'), findsNothing);
    expect(find.text('All tags'), findsNothing);
    expect(find.byTooltip('Refresh local catalog'), findsNothing);
    expect(find.text('Search'), findsOneWidget);
    expect(find.byTooltip('Previous book'), findsOneWidget);
    expect(find.byTooltip('Next book'), findsOneWidget);

    await tester.tap(find.text('Search'));
    await tester.pump();
    expect(find.text('Filter catalog text'), findsOneWidget);
    expect(find.text('All tags'), findsOneWidget);
    expect(find.byTooltip('Refresh local catalog'), findsOneWidget);
    expect(
      tester.getSize(find.byType(TextField)).height,
      tester.getSize(find.byTooltip('Filter by tag')).height,
    );
    expect(
      tester.getSize(find.byTooltip('Filter by tag')).height,
      tester.getSize(find.byTooltip('Refresh local catalog')).height,
    );

    await tester.tap(find.text('Search'));
    await tester.pump();
    expect(find.text('Filter catalog text'), findsNothing);
  });

  testWidgets('library navigation is available only in the catalog header', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await pumpCatalog(tester);

    final previous = tester.widget<IconButton>(
      catalogHeaderIconButton('Previous book'),
    );
    final next = tester.widget<IconButton>(
      catalogHeaderIconButton('Next book'),
    );
    expect(find.byTooltip('Previous book'), findsOneWidget);
    expect(find.byTooltip('Next book'), findsOneWidget);
    expect(previous.onPressed != null || next.onPressed != null, isTrue);

    final navigate = previous.onPressed != null
        ? find.byTooltip('Previous book')
        : find.byTooltip('Next book');
    await tester.tap(navigate);
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            catalogHeaderIconButton(
              previous.onPressed != null ? 'Next book' : 'Previous book',
            ),
          )
          .onPressed,
      isNotNull,
    );
  });
}
