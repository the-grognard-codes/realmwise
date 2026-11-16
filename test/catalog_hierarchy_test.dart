import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/catalog/catalog_hierarchy.dart';
import 'package:realmwise/models/catalog_models.dart';

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

List<Object> _shape(Iterable<CatalogHierarchyNode> nodes) => [
  for (final node in nodes)
    [node.tier.name, node.label, node.isFallback, _shape(node.children)],
];

Iterable<CatalogRecord> _walk(Iterable<CatalogHierarchyNode> nodes) sync* {
  for (final node in nodes) {
    if (node.tier == CatalogHierarchyTier.work) {
      expect(node.record, isNotNull);
      expect(node.children, isEmpty);
      yield node.record!;
    } else {
      expect(node.record, isNull);
      yield* _walk(node.children);
    }
  }
}

void main() {
  test('section icons use the existing persisted tier keys', () {
    expect(CatalogHierarchyTier.gameSystem.storedIconKey, 'gameSystem');
    expect(CatalogHierarchyTier.gameSetting.storedIconKey, 'gameSetting');
    expect(CatalogHierarchyTier.bookType.storedIconKey, 'bookType');
    expect(CatalogHierarchyTier.work.storedIconKey, isNull);
  });

  final records = [
    _record('untyped', system: ' S ', setting: ' A '),
    _record('no setting', system: 'S', type: 'Ignored'),
    _record('Z work', system: 'S', setting: 'A', type: 'Z type'),
    _record('A work', system: 'S', setting: 'Z', type: 'A type'),
    _record('fallback', system: '  ', setting: '  ', type: '  '),
  ];

  test('setting-first tree retains groups and direct work leaves', () {
    expect(_shape(buildCatalogHierarchy(records)), [
      [
        'gameSystem',
        'S',
        false,
        [
          [
            'gameSetting',
            'A',
            false,
            [
              [
                'bookType',
                'Z type',
                false,
                [
                  ['work', 'Z work', false, []],
                ],
              ],
              ['work', 'untyped', false, []],
            ],
          ],
          [
            'gameSetting',
            'Z',
            false,
            [
              [
                'bookType',
                'A type',
                false,
                [
                  ['work', 'A work', false, []],
                ],
              ],
            ],
          ],
          ['work', 'no setting', false, []],
        ],
      ],
      [
        'gameSystem',
        'Unclassified system',
        true,
        [
          ['work', 'fallback', false, []],
        ],
      ],
    ]);
  });

  test('type-first tree puts untyped then unset-setting works last', () {
    expect(
      _shape(
        buildCatalogHierarchy(
          records,
          order: CatalogHierarchyOrder.gameSystemBookTypeSetting,
        ),
      ),
      [
        [
          'gameSystem',
          'S',
          false,
          [
            [
              'bookType',
              'A type',
              false,
              [
                [
                  'gameSetting',
                  'Z',
                  false,
                  [
                    ['work', 'A work', false, []],
                  ],
                ],
              ],
            ],
            [
              'bookType',
              'Z type',
              false,
              [
                [
                  'gameSetting',
                  'A',
                  false,
                  [
                    ['work', 'Z work', false, []],
                  ],
                ],
              ],
            ],
            ['work', 'untyped', false, []],
            ['work', 'no setting', false, []],
          ],
        ],
        [
          'gameSystem',
          'Unclassified system',
          true,
          [
            ['work', 'fallback', false, []],
          ],
        ],
      ],
    );
  });

  for (final order in CatalogHierarchyOrder.values) {
    test('filtered subsets sort works within sections: $order', () {
      final source = [
        _record('guide-1', system: 'S', setting: 'Set', type: 'Guide'),
        _record('other', system: 'S', setting: 'Other', type: 'Core'),
        _record('guide-2', system: 'S', setting: 'Set', type: 'Guide'),
      ];
      final filtered = [source[2], source[0]];
      expect(
        flattenCatalogHierarchy(
          filtered,
          order: order,
        ).map((record) => record.work.title),
        ['guide-1', 'guide-2'],
      );
    });

    test('sorts every hierarchy level alphabetically: $order', () {
      final unsorted = [
        _record('Zulu', system: 'Zeta', setting: 'Zulu', type: 'Zulu'),
        _record('alpha', system: 'Alpha', setting: 'Zulu', type: 'Zulu'),
        _record('Beta', system: 'Alpha', setting: 'Alpha', type: 'Zulu'),
        _record('gamma', system: 'Alpha', setting: 'Alpha', type: 'Alpha'),
      ];
      expect(
        flattenCatalogHierarchy(
          unsorted,
          order: order,
        ).map((record) => record.work.title),
        ['gamma', 'Beta', 'alpha', 'Zulu'],
      );
    });

    test(
      'missing-setting works stay sorted directly under their system: $order',
      () {
        final missingSetting = [
          _record('typed missing setting', system: 'S', type: 'Type'),
          _record('untyped missing setting', system: 'S'),
          _record('with setting', system: 'S', setting: 'Set', type: 'Type'),
        ];
        expect(
          flattenCatalogHierarchy(
            missingSetting,
            order: order,
          ).map((record) => record.work.title),
          ['with setting', 'typed missing setting', 'untyped missing setting'],
        );
      },
    );

    test('flatten is the depth-first walk, retaining records: $order', () {
      final tree = buildCatalogHierarchy(records, order: order);
      final walked = _walk(tree).toList();
      expect(flattenCatalogHierarchy(records, order: order), walked);
      expect(walked, unorderedEquals(records));
      expect(records.first.work.title, 'untyped');
    });

    test('case-only sections stay distinct and titles break ties: $order', () {
      final caseRecords = [
        for (final system in ['s', 'S'])
          for (final setting in ['set', 'Set'])
            for (final type in ['type', 'Type'])
              for (final title in ['alpha', 'Alpha'])
                _record(title, system: system, setting: setting, type: type),
      ];
      final tree = buildCatalogHierarchy(caseRecords, order: order);
      expect(tree.map((node) => node.label), ['S', 's']);
      for (final system in tree) {
        expect(
          system.children.map((node) => node.label),
          order == CatalogHierarchyOrder.gameSystemSettingBookType
              ? ['Set', 'set']
              : ['Type', 'type'],
        );
        for (final second in system.children) {
          expect(
            second.children.map((node) => node.label),
            order == CatalogHierarchyOrder.gameSystemSettingBookType
                ? ['Type', 'type']
                : ['Set', 'set'],
          );
          for (final third in second.children) {
            expect(third.children.map((node) => node.label), [
              'Alpha',
              'alpha',
            ]);
          }
        }
      }
    });

    test('empty input and whitespace-only fields: $order', () {
      expect(buildCatalogHierarchy([], order: order), isEmpty);
      expect(flattenCatalogHierarchy([], order: order), isEmpty);
      final blank = _record('Work', system: ' ', setting: ' ', type: ' ');
      final tree = buildCatalogHierarchy([blank], order: order);
      expect(tree.single.label, 'Unclassified system');
      expect(tree.single.isFallback, isTrue);
      expect(tree.single.children.single.record, same(blank));
    });
  }

  test('a literal fallback label keeps the existing grouping collision', () {
    final tree = buildCatalogHierarchy([
      _record('Empty'),
      _record('Named', system: 'Unclassified system'),
    ]);
    expect(tree, hasLength(1));
    expect(tree.single.isFallback, isTrue);
    expect(tree.single.children.map((node) => node.label), ['Empty', 'Named']);
    expect(
      buildCatalogHierarchy([_record('Named', system: 'Unclassified system')])
          .single
          .isFallback,
      isFalse,
    );
  });
}
