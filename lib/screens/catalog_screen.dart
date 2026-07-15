import 'package:flutter/material.dart';

import '../models/catalog_models.dart';
import '../services/app_controller.dart';
import '../widgets/cover_image.dart';
import 'book_editor_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _filterController.addListener(_filter);
    _load();
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await Future.wait([
        widget.controller.catalog.listRecords(),
        widget.controller.catalog.allTags(),
      ]);
      if (!mounted) return;
      final loaded = values[0] as List<CatalogRecord>;
      setState(() {
        _records = loaded;
        _tags = values[1] as List<String>;
        _selected = loaded
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

  List<CatalogRecord> get _shown => _records
      .where((record) => record.matches(_filterController.text, _tag))
      .toList();

  Future<void> _edit(CatalogRecord record) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            BookEditorScreen(controller: widget.controller, record: record),
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
          records: _shown,
          selected: _selected,
          onSelected: (record) => setState(() => _selected = record),
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
            PopupMenuButton<String?>(
              tooltip: 'Filter by tag',
              onSelected: (tag) => setState(() => _tag = tag),
              itemBuilder: (context) => [
                CheckedPopupMenuItem<String?>(
                  value: null,
                  checked: _tag == null,
                  child: const Text('All tags'),
                ),
                ..._tags.map(
                  (tag) => CheckedPopupMenuItem<String?>(
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
    required this.records,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
  });
  final List<CatalogRecord> records;
  final CatalogRecord? selected;
  final ValueChanged<CatalogRecord> onSelected;
  final ValueChanged<CatalogRecord> onOpen;

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
              initiallyExpanded: true,
              leading: const Icon(Icons.account_tree_outlined),
              title: Text(system.key),
              children: _settingNodes(system.value),
            ),
          )
          .toList(),
    );
  }

  List<Widget> _settingNodes(List<CatalogRecord> systemRecords) {
    final settings = <String, List<CatalogRecord>>{};
    for (final record in systemRecords) {
      settings
          .putIfAbsent(
            _name(record.work.gameSetting, 'General setting'),
            () => [],
          )
          .add(record);
    }
    return settings.entries
        .map(
          (setting) => ExpansionTile(
            initiallyExpanded: true,
            tilePadding: const EdgeInsets.only(left: 28, right: 8),
            leading: const Icon(Icons.landscape_outlined),
            title: Text(setting.key),
            children: _typeNodes(setting.value),
          ),
        )
        .toList();
  }

  List<Widget> _typeNodes(List<CatalogRecord> settingRecords) {
    final types = <String, List<CatalogRecord>>{};
    for (final record in settingRecords) {
      types
          .putIfAbsent(
            _name(record.work.bookType, 'Unclassified type'),
            () => [],
          )
          .add(record);
    }
    return types.entries
        .map(
          (type) => ExpansionTile(
            initiallyExpanded: true,
            tilePadding: const EdgeInsets.only(left: 48, right: 8),
            leading: const Icon(Icons.book_outlined),
            title: Text(type.key),
            children: type.value
                .map(
                  (record) => ListTile(
                    contentPadding: const EdgeInsets.only(left: 72, right: 8),
                    selected: record.work.id == selected?.work.id,
                    leading: record.copies.any((copy) => copy.favorite)
                        ? const Icon(Icons.favorite, size: 18)
                        : null,
                    title: Text(
                      record.work.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      record.work.authors.isEmpty
                          ? 'No author recorded'
                          : record.work.authors.join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      record.copies.length == 1
                          ? '1 copy'
                          : '${record.copies.length} copies',
                    ),
                    onTap: () => onSelected(record),
                    onLongPress: () => onOpen(record),
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  String _name(String value, String fallback) =>
      value.trim().isEmpty ? fallback : value;
}

class _BookPreview extends StatelessWidget {
  const _BookPreview({required this.record, required this.onEdit});
  final CatalogRecord? record;
  final VoidCallback? onEdit;

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
                      Text(
                        work.title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        work.authors.isEmpty
                            ? 'Author information is not recorded.'
                            : work.authors.join(', '),
                      ),
                      const SizedBox(height: 16),
                      _Fact(label: 'ISBN-13', value: work.isbn13),
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
              const Text(
                  'Use Add book to look up a work or enter it manually.'),
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
