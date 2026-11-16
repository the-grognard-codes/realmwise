import '../models/catalog_models.dart';

enum CatalogHierarchyOrder {
  gameSystemSettingBookType,
  gameSystemBookTypeSetting,
}

/// A displayed group tier, or an individual work at a leaf.
enum CatalogHierarchyTier {
  gameSystem('gameSystem'),
  gameSetting('gameSetting'),
  bookType('bookType'),
  work(null);

  const CatalogHierarchyTier(this.storedIconKey);

  /// Persisted catalog-icon key, independent of the enum value's Dart name.
  /// Work leaves do not have a section icon.
  final String? storedIconKey;
}

/// One immutable node in the catalog's display order. Missing settings and
/// types are omitted rather than represented by synthetic groups.
class CatalogHierarchyNode {
  CatalogHierarchyNode._group({
    required this.tier,
    required this.label,
    required this.isFallback,
    required Iterable<CatalogHierarchyNode> children,
  }) : children = List.unmodifiable(children),
       record = null;

  CatalogHierarchyNode._work(CatalogRecord value)
    : tier = CatalogHierarchyTier.work,
      label = value.work.title,
      isFallback = false,
      children = const [],
      record = value;

  final CatalogHierarchyTier tier;
  final String label;
  final bool isFallback;
  final List<CatalogHierarchyNode> children;
  final CatalogRecord? record;
}

const _unclassifiedSystem = 'Unclassified system';

int _compareLabels(String a, String b) {
  final insensitive = a.toLowerCase().compareTo(b.toLowerCase());
  return insensitive != 0 ? insensitive : a.compareTo(b);
}

List<CatalogHierarchyNode> _works(Iterable<CatalogRecord> records) {
  final sorted = records.toList()
    ..sort((a, b) => _compareLabels(a.work.title, b.work.title));
  return sorted.map(CatalogHierarchyNode._work).toList();
}

String _sectionName(CatalogRecord record, CatalogHierarchyTier tier) =>
    switch (tier) {
      CatalogHierarchyTier.gameSystem => record.work.gameSystem.trim(),
      CatalogHierarchyTier.gameSetting => record.work.gameSetting.trim(),
      CatalogHierarchyTier.bookType => record.work.bookType.trim(),
      CatalogHierarchyTier.work => record.work.title,
    };

List<CatalogHierarchyNode> _groups(
  Iterable<CatalogRecord> records,
  CatalogHierarchyTier tier,
  List<CatalogHierarchyNode> Function(List<CatalogRecord>) children,
) {
  final groups = <String, List<CatalogRecord>>{};
  final unclassified = <CatalogRecord>[];
  for (final record in records) {
    final name = _sectionName(record, tier);
    if (name.isEmpty && tier != CatalogHierarchyTier.gameSystem) {
      unclassified.add(record);
    } else {
      final label = name.isEmpty ? _unclassifiedSystem : name;
      groups.putIfAbsent(label, () => []).add(record);
    }
  }
  final labels = groups.keys.toList()..sort(_compareLabels);
  return [
    for (final label in labels)
      CatalogHierarchyNode._group(
        tier: tier,
        label: label,
        isFallback: groups[label]!.any(
          (record) => _sectionName(record, tier).isEmpty,
        ),
        children: children(groups[label]!),
      ),
    ..._works(unclassified),
  ];
}

/// Builds the selector hierarchy, including sorted work leaves. In type-first
/// order, untyped works with a setting follow typed groups; works with no
/// setting follow those, directly under their system in either order.
List<CatalogHierarchyNode> buildCatalogHierarchy(
  Iterable<CatalogRecord> records, {
  CatalogHierarchyOrder order = CatalogHierarchyOrder.gameSystemSettingBookType,
}) => List.unmodifiable(
  _groups(records, CatalogHierarchyTier.gameSystem, (systemRecords) {
    if (order == CatalogHierarchyOrder.gameSystemSettingBookType) {
      return _groups(systemRecords, CatalogHierarchyTier.gameSetting, (
        records,
      ) {
        return _groups(records, CatalogHierarchyTier.bookType, _works);
      });
    }
    final withSetting = <CatalogRecord>[];
    final withoutSetting = <CatalogRecord>[];
    for (final record in systemRecords) {
      (record.work.gameSetting.trim().isEmpty ? withoutSetting : withSetting)
          .add(record);
    }
    return [
      ..._groups(withSetting, CatalogHierarchyTier.bookType, (records) {
        return _groups(records, CatalogHierarchyTier.gameSetting, _works);
      }),
      ..._works(withoutSetting),
    ];
  }),
);

Iterable<CatalogRecord> _leaves(Iterable<CatalogHierarchyNode> nodes) sync* {
  for (final node in nodes) {
    final record = node.record;
    if (record != null) {
      yield record;
    } else {
      yield* _leaves(node.children);
    }
  }
}

/// Returns the hierarchy's work leaves in display order.
List<CatalogRecord> flattenCatalogHierarchy(
  Iterable<CatalogRecord> records, {
  CatalogHierarchyOrder order = CatalogHierarchyOrder.gameSystemSettingBookType,
}) => List.unmodifiable(_leaves(buildCatalogHierarchy(records, order: order)));
