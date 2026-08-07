import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';

import '../data/database_service.dart';
import '../models/catalog_models.dart';
import '../services/app_controller.dart';
import '../widgets/cover_image.dart';
import 'book_editor_screen.dart';

/// Returns records in the same order in which the catalog hierarchy is
/// presented. Group insertion order and record order are preserved, matching
/// [_CatalogSelector]; untyped books remain after typed groups within a
/// setting.
List<CatalogRecord> flattenCatalogHierarchy(
  Iterable<CatalogRecord> records, {
  CatalogHierarchyOrder order = CatalogHierarchyOrder.gameSystemSettingBookType,
}) {
  String name(String raw, String fallback) =>
      raw.trim().isEmpty ? fallback : raw.trim();
  final source = records.toList(growable: false);
  final flattened = <CatalogRecord>[];
  if (order == CatalogHierarchyOrder.gameSystemBookTypeSetting) {
    final systems = <String, List<CatalogRecord>>{};
    for (final record in source)
      systems
          .putIfAbsent(
            name(record.work.gameSystem, 'Unclassified system'),
            () => [],
          )
          .add(record);
    for (final systemRecords in systems.values) {
      final types = <String, List<CatalogRecord>>{};
      final untyped = <CatalogRecord>[];
      final unsetSetting = <CatalogRecord>[];
      for (final record in systemRecords) {
        final type = record.work.bookType.trim();
        if (record.work.gameSetting.trim().isEmpty)
          unsetSetting.add(record);
        else if (type.isEmpty)
          untyped.add(record);
        else
          types.putIfAbsent(type, () => []).add(record);
      }
      for (final typeRecords in types.values) {
        final settings = <String, List<CatalogRecord>>{};
        for (final record in typeRecords)
          settings
              .putIfAbsent(
                name(record.work.gameSetting, 'Unspecified Setting'),
                () => [],
              )
              .add(record);
        for (final settingRecords in settings.values)
          flattened.addAll(settingRecords);
      }
      flattened.addAll(untyped);
      flattened.addAll(unsetSetting);
    }
  } else {
    final systems = <String, List<CatalogRecord>>{};
    for (final record in source)
      systems
          .putIfAbsent(
            name(record.work.gameSystem, 'Unclassified system'),
            () => [],
          )
          .add(record);
    for (final systemRecords in systems.values) {
      final settings = <String, List<CatalogRecord>>{};
      final unsetSetting = <CatalogRecord>[];
      for (final record in systemRecords)
        if (record.work.gameSetting.trim().isEmpty)
          unsetSetting.add(record);
        else
          settings
              .putIfAbsent(record.work.gameSetting.trim(), () => [])
              .add(record);
      for (final settingRecords in settings.values) {
        final types = <String, List<CatalogRecord>>{};
        final untyped = <CatalogRecord>[];
        for (final record in settingRecords) {
          final type = record.work.bookType.trim();
          if (type.isEmpty)
            untyped.add(record);
          else
            types.putIfAbsent(type, () => []).add(record);
        }
        for (final typeRecords in types.values) flattened.addAll(typeRecords);
        flattened.addAll(untyped);
      }
      // A missing setting is not a meaningful hierarchy level. Keep these
      // books directly under their game system rather than creating a
      // synthetic "Unspecified Setting" group.
      flattened.addAll(unsetSetting);
    }
  }
  return List.unmodifiable(flattened);
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final _filterController = TextEditingController();
  List<CatalogRecord> _records = const [];
  List<String> _tags = const [];
  String? _tag;
  CatalogRecord? _selected;
  bool _loading = true;
  String? _error;
  List<CatalogIconMapping> _icons = const [];

  @override
  void initState() {
    super.initState();
    _filterController.addListener(_filter);
    widget.controller.addListener(_controllerChanged);
    _load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _filterController.dispose();
    super.dispose();
  }

  void _controllerChanged() => mounted ? setState(() {}) : null;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await Future.wait([
        widget.controller.catalog.listRecords(),
        widget.controller.catalog.allTags(),
        widget.controller.database.listCatalogIcons(),
      ]);
      if (!mounted) return;
      final loaded = values[0] as List<CatalogRecord>;
      widget.controller.observeCatalogRecords(loaded);
      setState(() {
        _records = loaded;
        _tags = values[1] as List<String>;
        _icons = values[2] as List<CatalogIconMapping>;
        _selected =
            loaded
                .where((record) => record.work.id == _selected?.work.id)
                .firstOrNull ??
            (loaded.isEmpty ? null : loaded.first);
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filter() => setState(() {});

  int get _selectedIndex {
    final selected = _selected;
    if (selected == null) return -1;
    return _navigationRecords.indexWhere(
      (record) =>
          (selected.work.id != null && record.work.id == selected.work.id) ||
          identical(record, selected),
    );
  }

  void _selectRelative(int delta) {
    final shown = _navigationRecords;
    final index = _selectedIndex + delta;
    if (index < 0 || index >= shown.length) return;
    final record = shown[index];
    widget.controller.clearSessionNewWork(record.work.id);
    setState(() => _selected = record);
  }

  List<CatalogRecord> get _shown => _records
      .where((record) => record.matches(_filterController.text, _tag))
      .toList();

  List<CatalogRecord> get _navigationRecords =>
      flattenCatalogHierarchy(_shown, order: widget.controller.hierarchyOrder);

  Future<void> _edit(CatalogRecord record) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => BookEditorScreen(
          controller: widget.controller,
          record: record,
          navigationRecords: _navigationRecords,
          navigationIndex: _navigationRecords.indexWhere(
            (item) =>
                (record.work.id != null && item.work.id == record.work.id) ||
                identical(item, record),
          ),
        ),
      ),
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _ErrorPanel(message: _error!, retry: _load);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final selector = _CatalogSelector(
          controller: widget.controller,
          records: _shown,
          icons: _icons,
          selected: _selected,
          onSelected: (record) {
            widget.controller.clearSessionNewWork(record.work.id);
            setState(() => _selected = record);
          },
          onOpen: _edit,
        );
        return Column(
          children: [
            _catalogTools(),
            Expanded(
              child: _records.isEmpty
                  ? const _EmptyCatalog()
                  : wide
                  ? Row(
                      children: [
                        SizedBox(width: 370, child: selector),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: _BookPreview(
                            record: _selected,
                            onEdit: _selected == null
                                ? null
                                : () => _edit(_selected!),
                            onPrevious: _selectedIndex > 0
                                ? () => _selectRelative(-1)
                                : null,
                            onNext:
                                _selectedIndex >= 0 &&
                                    _selectedIndex <
                                        _navigationRecords.length - 1
                                ? () => _selectRelative(1)
                                : null,
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(flex: 3, child: selector),
                        const Divider(height: 1),
                        Expanded(
                          flex: 4,
                          child: _BookPreview(
                            record: _selected,
                            onEdit: _selected == null
                                ? null
                                : () => _edit(_selected!),
                            onPrevious: _selectedIndex > 0
                                ? () => _selectRelative(-1)
                                : null,
                            onNext:
                                _selectedIndex >= 0 &&
                                    _selectedIndex <
                                        _navigationRecords.length - 1
                                ? () => _selectRelative(1)
                                : null,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _catalogTools() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _filterController,
            decoration: InputDecoration(
              labelText: 'Filter catalog text',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _filterController.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () => _filterController.clear(),
                      icon: const Icon(Icons.clear),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          tooltip: 'Filter by tag',
          onSelected: (tag) => setState(() => _tag = tag.isEmpty ? null : tag),
          itemBuilder: (context) => [
            // Popup menus treat a null value as dismissal, so use an empty
            // sentinel for the explicit "All tags" choice.
            CheckedPopupMenuItem<String>(
              value: '',
              checked: _tag == null,
              child: const Text('All tags'),
            ),
            ..._tags.map(
              (tag) => CheckedPopupMenuItem<String>(
                value: tag,
                checked: _tag == tag,
                child: Text(tag),
              ),
            ),
          ],
          child: Chip(
            avatar: const Icon(Icons.sell_outlined, size: 18),
            label: Text(_tag ?? 'All tags'),
          ),
        ),
        IconButton(
          onPressed: _load,
          tooltip: 'Refresh local catalog',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
  );
}

class _CatalogSelector extends StatelessWidget {
  const _CatalogSelector({
    required this.controller,
    required this.records,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
    required this.icons,
  });
  final AppController controller;
  final List<CatalogRecord> records;
  final CatalogRecord? selected;
  final ValueChanged<CatalogRecord> onSelected;
  final ValueChanged<CatalogRecord> onOpen;
  final List<CatalogIconMapping> icons;

  Widget _leading(
    BuildContext context,
    String tier,
    String name,
    IconData fallback,
  ) {
    final m = icons
        .where((x) => x.tier == tier && x.sectionName == name)
        .firstOrNull;
    if (m == null || !File(m.localPath).existsSync()) return Icon(fallback);
    // Category images are easier to recognize when their corners remain
    // visible. Keep book-type icons circular while using a small rounded
    // square for game systems and settings.
    final frame = SizedBox(
      width: 24,
      height: 24,
      child: ClipRect(
        child: Transform.scale(
          scale: m.zoom,
          child: Image.file(
            File(m.localPath),
            width: 24,
            height: 24,
            fit: BoxFit.contain,
            alignment: Alignment(m.alignmentX, m.alignmentY),
          ),
        ),
      ),
    );
    return tier == 'bookType'
        ? ClipOval(child: frame)
        : ClipRRect(borderRadius: BorderRadius.circular(6), child: frame);
  }

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty)
      return const Center(child: Text('No matching books or tags.'));
    final systems = <String, List<CatalogRecord>>{};
    for (final record in records) {
      systems
          .putIfAbsent(
            _name(record.work.gameSystem, 'Unclassified system'),
            () => [],
          )
          .add(record);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: systems.entries
          .map(
            (system) => ExpansionTile(
              initiallyExpanded: false,
              leading: _leading(
                context,
                'gameSystem',
                system.key,
                Icons.account_tree_outlined,
              ),
              title: Text(system.key),
              children:
                  controller.hierarchyOrder ==
                      CatalogHierarchyOrder.gameSystemBookTypeSetting
                  ? _typeFirstNodes(context, system.value)
                  : _settingNodes(context, system.value),
            ),
          )
          .toList(),
    );
  }

  List<Widget> _typeFirstNodes(
    BuildContext context,
    List<CatalogRecord> records,
  ) {
    final types = <String, List<CatalogRecord>>{};
    final untyped = <CatalogRecord>[];
    final unsetSetting = <CatalogRecord>[];
    for (final record in records) {
      final type = record.work.bookType.trim();
      if (record.work.gameSetting.trim().isEmpty)
        unsetSetting.add(record);
      else if (type.isEmpty)
        untyped.add(record);
      else
        types.putIfAbsent(type, () => []).add(record);
    }
    return [
      ...types.entries.map(
        (type) => ExpansionTile(
          tilePadding: const EdgeInsets.only(left: 28, right: 8),
          leading: _leading(context, 'bookType', type.key, Icons.book_outlined),
          title: Text(type.key),
          children: _settingNodes(
            context,
            type.value,
            left: 48,
            includeTypes: false,
          ),
        ),
      ),
      ...untyped.expand((record) => _recordTiles(record, left: 28)),
      ...unsetSetting.expand((record) => _recordTiles(record, left: 28)),
    ];
  }

  List<Widget> _settingNodes(
    BuildContext context,
    List<CatalogRecord> systemRecords, {
    double left = 28,
    bool includeTypes = true,
  }) {
    final settings = <String, List<CatalogRecord>>{};
    final unsetSetting = <CatalogRecord>[];
    for (final record in systemRecords) {
      if (record.work.gameSetting.trim().isEmpty)
        unsetSetting.add(record);
      else
        settings
            .putIfAbsent(record.work.gameSetting.trim(), () => [])
            .add(record);
    }
    return [
      ...settings.entries.map(
        (setting) => ExpansionTile(
          initiallyExpanded: false,
          tilePadding: EdgeInsets.only(left: left, right: 8),
          leading: _leading(
            context,
            'gameSetting',
            setting.key,
            Icons.landscape_outlined,
          ),
          title: Text(setting.key),
          children: includeTypes
              ? _typeNodes(context, setting.value)
              : setting.value
                    .expand((record) => _recordTiles(record, left: left + 20))
                    .toList(),
        ),
      ),
      ...unsetSetting.expand((record) => _recordTiles(record, left: left)),
    ];
  }

  List<Widget> _typeNodes(
    BuildContext context,
    List<CatalogRecord> settingRecords,
  ) {
    final types = <String, List<CatalogRecord>>{};
    final untyped = <CatalogRecord>[];
    for (final record in settingRecords) {
      final type = record.work.bookType.trim();
      if (type.isEmpty) {
        // A missing type is not a meaningful hierarchy level. Keep the book
        // directly under its setting instead of creating a synthetic group.
        untyped.add(record);
      } else {
        types.putIfAbsent(type, () => []).add(record);
      }
    }
    return [
      ...types.entries.map(
        (type) => ExpansionTile(
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.only(left: 48, right: 8),
          leading: _leading(context, 'bookType', type.key, Icons.book_outlined),
          title: Text(type.key),
          children: type.value
              .expand((record) => _recordTiles(record, left: 72))
              .toList(),
        ),
      ),
      ...untyped.expand((record) => _recordTiles(record, left: 48)),
    ];
  }

  Iterable<Widget> _recordTiles(CatalogRecord record, {required double left}) {
    // A record normally has one row per owned copy. Keep a title-only fallback
    // for malformed/empty records so the work remains reachable in the
    // hierarchy.
    final copies = record.copies;
    final Iterable<MapEntry<int, UserCopy?>> entries = copies.isEmpty
        ? <MapEntry<int, UserCopy?>>[const MapEntry(0, null)]
        : copies.asMap().entries.map(
            (entry) => MapEntry(entry.key, entry.value),
          );
    return entries.map(
      (entry) => ListTile(
        contentPadding: EdgeInsets.only(left: left, right: 8),
        selected: record.work.id == selected?.work.id,
        leading: entry.value?.favorite == true
            ? const Icon(Icons.favorite, size: 18)
            : null,
        title: Row(
          children: [
            if (record.work.id != null &&
                controller.sessionNewWorkIds.contains(record.work.id)) ...[
              const _NewBadge(),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                record.work.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        trailing: copies.length > 1 ? Text('copy ${entry.key + 1}') : null,
        onTap: () => onSelected(record),
        onLongPress: () => onOpen(record),
      ),
    );
  }

  String _name(String value, String fallback) =>
      value.trim().isEmpty ? fallback : value.trim();
}

class _NewBadge extends StatelessWidget {
  const _NewBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary,
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      'NEW',
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onPrimary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

class _BookPreview extends StatelessWidget {
  const _BookPreview({
    required this.record,
    required this.onEdit,
    required this.onPrevious,
    required this.onNext,
  });
  final CatalogRecord? record;
  final VoidCallback? onEdit;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    if (record == null)
      return const Center(child: Text('Select a book to see its details.'));
    final work = record!.work;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 790),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sideBySide = constraints.maxWidth > 540;
                  final cover = CoverImage(
                    image: record!.cover,
                    width: sideBySide ? 230 : 180,
                    height: sideBySide ? 330 : 255,
                  );
                  final details = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              work.title,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ),
                          IconButton(
                            onPressed: onPrevious,
                            tooltip: 'Previous book',
                            icon: const Icon(Icons.arrow_back),
                          ),
                          IconButton(
                            onPressed: onNext,
                            tooltip: 'Next book',
                            icon: const Icon(Icons.arrow_forward),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        work.authors.isEmpty
                            ? 'Author information is not recorded.'
                            : work.authors.join(', '),
                      ),
                      const SizedBox(height: 16),
                      _Fact(label: 'ISBN-13', value: work.isbn13),
                      _RpgGeekField(id: work.rpgGeekId, url: work.rpgGeekUrl),
                      _Fact(label: 'Publisher', value: work.publisher),
                      _Fact(label: 'Published', value: work.publicationDate),
                      _Fact(
                        label: 'Pages',
                        value: work.pageCount?.toString() ?? '',
                      ),
                      _Fact(label: 'Copies', value: '${record!.copies.length}'),
                      _Fact(
                        label: 'Tags',
                        value: record!.tags.isEmpty
                            ? 'No tags'
                            : record!.tags.join(', '),
                      ),
                      if (work.summary.trim().isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          work.summary,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ] else ...[
                        const SizedBox(height: 16),
                        const Text('No summary is recorded for this work.'),
                      ],
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit),
                        label: const Text('View full details / edit'),
                      ),
                    ],
                  );
                  return sideBySide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            cover,
                            const SizedBox(width: 24),
                            Expanded(child: details),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Center(child: cover),
                            const SizedBox(height: 20),
                            details,
                          ],
                        );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => value.trim().isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('$label: $value'),
        );
}

class _RpgGeekField extends StatelessWidget {
  const _RpgGeekField({required this.id, required this.url});
  final String id;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final trimmedId = id.trim();
    if (url == null || trimmedId.isEmpty) {
      return const Text('RPGGeek Thing ID: No Info');
    }
    return Text.rich(
      TextSpan(
        text: 'RPGGeek Thing ID: ',
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: InkWell(
              onTap: () => _openRpgGeek(context, url),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  trimmedId,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _openRpgGeek(BuildContext context, String? url) async {
  if (url == null) return;
  try {
    final launched = await launchUrl(Uri.parse(url));
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open RPGGeek link.')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open RPGGeek link.')),
      );
    }
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 68,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'Your shelf is empty',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text('Use Add book to look up a work or enter it manually.'),
        ],
      ),
    ),
  );
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.retry});
  final String message;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: retry, child: const Text('Try again')),
      ],
    ),
  );
}

extension _FirstCatalogOrNull on Iterable<CatalogRecord> {
  CatalogRecord? get firstOrNull => isEmpty ? null : first;
}

extension _FirstIconOrNull on Iterable<CatalogIconMapping> {
  CatalogIconMapping? get firstOrNull => isEmpty ? null : first;
}
