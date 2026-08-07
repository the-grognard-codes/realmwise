import 'package:flutter_test/flutter_test.dart';

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
    id: title.hashCode,
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
      'zeta',
      'alpha',
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

  test('filtered subsets retain supplied traversal order within sections', () {
    final records = [
      _record('guide-1', system: 'S', setting: 'Set', type: 'Guide'),
      _record('other', system: 'S', setting: 'Other', type: 'Core'),
      _record('guide-2', system: 'S', setting: 'Set', type: 'Guide'),
    ];
    final filtered = [records[2], records[0]];
    expect(
      flattenCatalogHierarchy(filtered).map((record) => record.work.title),
      ['guide-2', 'guide-1'],
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
      'setting-a',
      'setting-b',
      'other-type',
      'untyped',
    ]);
  });
}
