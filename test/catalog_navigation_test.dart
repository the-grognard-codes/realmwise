import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:realmwise/services/secure_storage_service.dart';

import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/screens/catalog_screen.dart';
import 'package:realmwise/services/app_controller.dart';

CatalogRecord _record(
  String title, {
  String system = '',
  String setting = '',
  String type = '',
}) => CatalogRecord(
  work: BookWork(
    title: title,
    gameSystem: system,
    gameSetting: setting,
    bookType: type,
  ),
);

void main() {
  test('navigation follows the selector hierarchy traversal', () {
    final records = [
      _record('zeta', system: 'Fantasy', setting: 'Core', type: 'Guide'),
      _record('Beta', system: 'fantasy', setting: 'core', type: 'Guide'),
      _record('alpha', system: 'Fantasy', setting: 'Core', type: 'Core'),
      _record('Untyped', system: 'Fantasy', setting: 'Core'),
      _record('General', system: 'Fantasy'),
      _record('Other'),
    ];

    final ordered = flattenCatalogHierarchy(records);
    expect(ordered.map((record) => record.work.title).toList(), [
      'alpha',
      'zeta',
      'Untyped',
      'General',
      'Beta',
      'Other',
    ]);
  });

  test('empty values use selector fallbacks and untyped books stay last', () {
    final records = [
      _record('Untyped', system: 'S', setting: 'Set'),
      _record('Typed', system: 'S', setting: 'Set', type: 'Type'),
      _record('No setting', system: 'S'),
    ];

    final ordered = flattenCatalogHierarchy(records);
    expect(ordered.map((record) => record.work.title), [
      'Typed',
      'Untyped',
      'No setting',
    ]);
  });

  test('books without a setting stay directly under their game system', () {
    final records = [
      _record('typed missing setting', system: 'S', type: 'Type'),
      _record('untyped missing setting', system: 'S'),
      _record('with setting', system: 'S', setting: 'Set', type: 'Type'),
    ];

    expect(
      flattenCatalogHierarchy(records).map((record) => record.work.title),
      ['with setting', 'typed missing setting', 'untyped missing setting'],
    );
    expect(
      flattenCatalogHierarchy(
        records,
        order: CatalogHierarchyOrder.gameSystemBookTypeSetting,
      ).map((record) => record.work.title),
      ['with setting', 'typed missing setting', 'untyped missing setting'],
    );
  });

  test('filtered subsets sort works within sections', () {
    final records = [
      _record('guide-1', system: 'S', setting: 'Set', type: 'Guide'),
      _record('other', system: 'S', setting: 'Other', type: 'Core'),
      _record('guide-2', system: 'S', setting: 'Set', type: 'Guide'),
    ];
    final filtered = [records[2], records[0]];
    expect(
      flattenCatalogHierarchy(filtered).map((record) => record.work.title),
      ['guide-1', 'guide-2'],
    );
  });

  test('supports game system, book type, setting order', () {
    final records = [
      _record('setting-a', system: 'S', setting: 'A', type: 'Type'),
      _record('setting-b', system: 'S', setting: 'B', type: 'Type'),
      _record('other-type', system: 'S', setting: 'A', type: 'Other'),
      _record('untyped', system: 'S', setting: 'A'),
    ];
    final ordered = flattenCatalogHierarchy(
      records,
      order: CatalogHierarchyOrder.gameSystemBookTypeSetting,
    );
    expect(ordered.map((record) => record.work.title), [
      'other-type',
      'setting-a',
      'setting-b',
      'untyped',
    ]);
  });

  test('sorts every hierarchy level alphabetically', () {
    final records = [
      _record('Zulu', system: 'Zeta', setting: 'Zulu', type: 'Zulu'),
      _record('alpha', system: 'Alpha', setting: 'Zulu', type: 'Zulu'),
      _record('Beta', system: 'Alpha', setting: 'Alpha', type: 'Zulu'),
      _record('gamma', system: 'Alpha', setting: 'Alpha', type: 'Alpha'),
    ];

    expect(
      flattenCatalogHierarchy(records).map((record) => record.work.title),
      ['gamma', 'Beta', 'alpha', 'Zulu'],
    );
    expect(
      flattenCatalogHierarchy(
        records,
        order: CatalogHierarchyOrder.gameSystemBookTypeSetting,
      ).map((record) => record.work.title),
      ['gamma', 'Beta', 'alpha', 'Zulu'],
    );
  });
  _navigationWidgetTests();
}

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

const _iconPaths = {
  'gameSystem': 'assets/icons/game-settings/d&d-al-qadim-icon.png',
  'gameSetting': 'assets/icons/game-settings/d&d-birthright-icon.png',
  'bookType': 'assets/icons/game-settings/d&d-blackmoor-icon.png',
};

void _navigationWidgetTests() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('selector and navigation share their hierarchy', () {
    late Directory folder;
    late AppController controller;
    late PathProviderPlatform previousPathProvider;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('realmwise_hierarchy_');
      previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(folder.path);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      controller = AppController(tokenStorage: _MemoryTokenStorage());
      await controller.openDatabase(
        '${folder.path}/catalog.db',
        remember: false,
      );
      for (final record in [
        _record(
          'First',
          system: 'System',
          setting: 'A setting',
          type: 'Z type',
        ),
        _record(
          'Second',
          system: 'System',
          setting: 'Z setting',
          type: 'A type',
        ),
        _record('Third', system: 'System', setting: 'A setting'),
        _record('Fourth', system: 'System', type: 'A type'),
        _record(
          'Fifth',
          system: 'System',
          setting: 'A setting',
          type: 'A type',
        ),
        _record('No system'),
      ]) {
        await controller.database.saveRecord(record);
      }
      for (final (tier, label) in [
        ('gameSystem', 'System'),
        ('gameSetting', 'A setting'),
        ('bookType', 'A type'),
      ]) {
        await controller.database.upsertCatalogIcon(
          CatalogIconMapping(
            tier: tier,
            sectionName: label,
            localPath: _iconPaths[tier]!,
          ),
        );
      }
    });

    tearDown(() async {
      await controller.closeDatabase();
      controller.dispose();
      PathProviderPlatform.instance = previousPathProvider;
      await folder.delete(recursive: true);
    });

    for (final width in [400.0, 1000.0]) {
      testWidgets('visible groups and next/previous agree at width $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: CatalogScreen(controller: controller)),
          ),
        );
        // Wait for the real catalog read without waiting on loading animations.
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (find.byTooltip('Next book').evaluate().isNotEmpty) break;
        }
        expect(find.byTooltip('Next book'), findsOneWidget);

        for (final order in CatalogHierarchyOrder.values) {
          await tester.runAsync(() => controller.setHierarchyOrder(order));
          await tester.pumpAndSettle();
          if (width < 900) {
            await tester.tap(find.byTooltip('Open library'));
            await tester.pumpAndSettle();
          }
          // Expand top-down through the actual controls, retaining a single
          // visible ListView whose tile positions describe display order.
          final expanded = <Element>{};
          while (true) {
            final pending = find
                .byType(ExpansionTile)
                .evaluate()
                .where((element) => !expanded.contains(element))
                .toList();
            if (pending.isEmpty) break;
            for (final element in pending) {
              expanded.add(element);
              final tile = find
                  .descendant(
                    of: find.byWidget(element.widget),
                    matching: find.byType(ListTile),
                  )
                  .first;
              await tester.ensureVisible(tile);
              await tester.tap(tile);
              await tester.pumpAndSettle();
            }
          }
          final list = find.byType(ListView);
          expect(list, findsOneWidget);
          final tiles = tester
              .widgetList<ListTile>(
                find.descendant(of: list, matching: find.byType(ListTile)),
              )
              .toList();
          final labels = [
            for (final tile in tiles)
              if (tile.title is Text)
                (tile.title! as Text).data!
              else
                tester
                    .widget<Text>(
                      find
                          .descendant(
                            of: find.byWidget(tile.title!),
                            matching: find.byType(Text),
                          )
                          .last,
                    )
                    .data!,
          ];
          final settingFirst =
              order == CatalogHierarchyOrder.gameSystemSettingBookType;
          expect(
            labels,
            settingFirst
                ? [
                    'System',
                    'A setting',
                    'A type',
                    'Fifth',
                    'Z type',
                    'First',
                    'Third',
                    'Z setting',
                    'A type',
                    'Second',
                    'Fourth',
                    'Unclassified system',
                    'No system',
                  ]
                : [
                    'System',
                    'A type',
                    'A setting',
                    'Fifth',
                    'Z setting',
                    'Second',
                    'Z type',
                    'A setting',
                    'First',
                    'Third',
                    'Fourth',
                    'Unclassified system',
                    'No system',
                  ],
          );
          // The three tiers retain their existing icons and group indentation.
          final groups = tiles.where((tile) => tile.title is Text).toList();
          for (final tile in groups) {
            final label = (tile.title! as Text).data!;
            final expectedIcon = label.contains('type')
                ? Icons.book_outlined
                : label.contains('setting')
                ? Icons.landscape_outlined
                : Icons.account_tree_outlined;
            final customTier = switch (label) {
              'System' => 'gameSystem',
              'A setting' => 'gameSetting',
              'A type' => 'bookType',
              _ => null,
            };
            if (customTier == null) {
              expect((tile.leading! as Icon).icon, expectedIcon);
            } else {
              final image = tester.widget<Image>(
                find.descendant(
                  of: find.byWidget(tile.leading!),
                  matching: find.byType(Image),
                ),
              );
              expect(
                (image.image as FileImage).file.path,
                _iconPaths[customTier],
              );
              expect(
                tile.leading,
                customTier == 'bookType' ? isA<ClipOval>() : isA<ClipRRect>(),
              );
            }
          }
          final titles = labels
              .where(
                (label) => [
                  'First',
                  'Second',
                  'Third',
                  'Fourth',
                  'Fifth',
                  'No system',
                ].contains(label),
              )
              .toList();
          final leaves = tiles.where((tile) => tile.title is! Text).toList();
          for (var i = 0; i < leaves.length; i++) {
            final expectedLeft = switch (titles[i]) {
              'First' || 'Second' || 'Fifth' => settingFirst ? 72.0 : 68.0,
              'Third' => settingFirst ? 48.0 : 28.0,
              _ => 28.0,
            };
            expect(
              leaves[i].contentPadding,
              EdgeInsets.only(left: expectedLeft, right: 8),
            );
          }
          final firstLeaf = find
              .ancestor(
                of: find.descendant(
                  of: list,
                  matching: find.text(titles.first),
                ),
                matching: find.byType(ListTile),
              )
              .last;
          await tester.ensureVisible(firstLeaf);
          await tester.tap(firstLeaf);
          await tester.pumpAndSettle();
          for (var i = 0; i < titles.length; i++) {
            if (i > 0) {
              await tester.tap(find.byTooltip('Next book'));
              await tester.pumpAndSettle();
            }
            expect(
              find.descendant(
                of: find.byType(SingleChildScrollView),
                matching: find.text(titles[i]),
              ),
              findsOneWidget,
            );
          }
          final next = tester.widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Next book'),
              matching: find.byType(IconButton),
            ),
          );
          expect(next.onPressed, isNull);
          for (final title in titles.reversed.skip(1)) {
            await tester.tap(find.byTooltip('Previous book'));
            await tester.pumpAndSettle();
            expect(
              find.descendant(
                of: find.byType(SingleChildScrollView),
                matching: find.text(title),
              ),
              findsOneWidget,
            );
          }
          final previous = tester.widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Previous book'),
              matching: find.byType(IconButton),
            ),
          );
          expect(previous.onPressed, isNull);
          // Collapse before switching order on desktop so old expansion state
          // cannot affect the next iteration's traversal.
          if (width >= 900) {
            for (final tile
                in find.byType(ExpansionTile).evaluate().toList().reversed) {
              await tester.tap(
                find
                    .descendant(
                      of: find.byWidget(tile.widget),
                      matching: find.byType(ListTile),
                    )
                    .first,
              );
              await tester.pumpAndSettle();
            }
          }
        }
      });
    }
  });
}
