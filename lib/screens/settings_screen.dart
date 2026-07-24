import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/app_controller.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _key;
  bool _showKey = false;
  bool _loading = true;
  bool _busy = false;
  List<File> _backups = const [];
  String _iconTier = 'gameSystem';
  String? _iconSection;
  String? _iconPreviewPath;
  String? _iconSourcePath;
  double _iconX = 0, _iconY = 0, _iconZoom = 1;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final key = await widget.controller.rpgGeekKey();
      final backups = await widget.controller.catalog.listBackups();
      if (mounted)
        setState(() {
          _key.text = key;
          _backups = backups;
        });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && success != null)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(success)));
      await _load();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not complete action: $error')),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveKey() => _run(
        () => widget.controller.setRpgGeekKey(_key.text),
        success: 'RPGGeek key saved in this local database.',
      );

  Future<void> _chooseImageFolder() async {
    final chosen = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose local image folder',
    );
    if (chosen != null)
      await _run(
        () => widget.controller.setImageFolder(chosen),
        success: 'New images will be stored in the selected folder.',
      );
  }

  Future<void> _saveCatalogIcon() async {
    final section = _iconSection;
    if (section == null) return;
    final source = _iconSourcePath;
    if (source == null) return;
    await _run(() => widget.controller.saveCatalogIcon(tier: _iconTier, sectionName: section, sourcePath: source, alignmentX: _iconX, alignmentY: _iconY, zoom: _iconZoom), success: 'Catalog icon saved.');
    if (mounted) setState(() => _iconSourcePath = null);
    await _selectIconSection(section);
  }

  Future<void> _chooseCatalogIcon() async {
    if (_iconSection == null) return;
    final picked = await FilePicker.pickFiles(type: FileType.image, dialogTitle: 'Choose catalog icon');
    final source = picked?.files.singleOrNull?.path;
    if (source == null || !mounted) return;
    setState(() {
      _iconSourcePath = source;
      _iconPreviewPath = source;
    });
  }

  Future<void> _selectIconSection(String? value) async {
    final tier = _iconTier;
    setState(() {
      _iconSection = value;
      _iconPreviewPath = null;
      _iconSourcePath = null;
      _iconX = 0;
      _iconY = 0;
      _iconZoom = 1;
    });
    if (value == null) return;
    final mapping = await widget.controller.database.getCatalogIcon(tier, value);
    if (mounted && _iconTier == tier && _iconSection == value)
      setState(() {
        _iconPreviewPath = mapping?.localPath;
        _iconX = mapping?.alignmentX ?? 0;
        _iconY = mapping?.alignmentY ?? 0;
        _iconZoom = mapping?.zoom ?? 1;
      });
  }

  Future<void> _removeCatalogIcon() async {
    final section = _iconSection;
    if (section == null) return;
    await _run(() => widget.controller.removeCatalogIcon(_iconTier, section), success: 'Catalog icon removed.');
    if (mounted && _iconSection == section) setState(() { _iconPreviewPath = null; _iconSourcePath = null; });
  }

  Widget _slider(String label, double value, ValueChanged<double> onChanged, double min, double max) => Semantics(
        label: label,
        value: value.toStringAsFixed(2),
        child: Row(children: [SizedBox(width: 125, child: Text(label)), Expanded(child: Slider(value: value, min: min, max: max, label: value.toStringAsFixed(2), onChanged: onChanged))]),
      );

  Future<void> _openDatabase() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['db', 'sqlite', 'sqlite3'],
      dialogTitle: 'Open catalog database',
    );
    final chosen = result?.files.singleOrNull?.path;
    if (chosen != null)
      await _run(
        () => widget.controller.openDatabase(chosen),
        success: 'Database opened.',
      );
  }

  Future<void> _newDatabase() async {
    final name = TextEditingController(text: 'rpg_catalog');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create and open a database'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Database name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (accepted == true)
      await _run(
        () => widget.controller.createDatabase(name.text),
        success: 'New database created and opened.',
      );
    name.dispose();
  }

  Future<void> _restore() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['db', 'sqlite', 'sqlite3'],
      dialogTitle: 'Choose a backup database to restore',
    );
    final backup = picked?.files.singleOrNull?.path;
    if (backup != null)
      await _run(
        () => widget.controller.restoreFromBackup(backup),
        success: 'Backup restored into a new active database.',
      );
  }

  Future<void> _close() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close current database?'),
        content: const Text(
          'The catalog is saved. You will be returned to the database selection screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close database'),
          ),
        ],
      ),
    );
    if (yes == true) await widget.controller.closeDatabase();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 44),
          children: [
            _Section(
              title: 'Appearance',
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: themeSeeds.entries.map((entry) {
                  final selected = entry.key == widget.controller.seedName;
                  return ChoiceChip(
                    selected: selected,
                    onSelected: _busy
                        ? null
                        : (value) {
                            if (value)
                              _run(() => widget.controller.setTheme(entry.key));
                          },
                    avatar: CircleAvatar(
                      backgroundColor: entry.value,
                      radius: 10,
                    ),
                    label: Text(entry.key),
                  );
                }).toList(),
              ),
            ),
            _Section(
              title: 'RPGGeek enrichment',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Optional. The key is stored only in the currently open local database and sent only when enriching a selected search result.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _key,
                    obscureText: !_showKey,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'RPGGeek API key',
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _showKey = !_showKey),
                        icon: Icon(
                          _showKey ? Icons.visibility_off : Icons.visibility,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _busy ? null : _saveKey,
                    icon: const Icon(Icons.key),
                    label: const Text('Save API key'),
                  ),
                ],
              ),
            ),
            _Section(
              title: 'Local image library',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(widget.controller.imageStorage.rootPath),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _chooseImageFolder,
                    icon: const Icon(Icons.folder_outlined),
                    label: const Text('Change image folder'),
                  ),
                ],
              ),
            ),
            _Section(
              title: 'Custom catalog icons',
              child: FutureBuilder<List<String>>(
                future: widget.controller.database.listCatalogTierSections(_iconTier),
                builder: (context, snap) => LayoutBuilder(
                  builder: (context, c) {
                    final controls = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                  DropdownButton<String>(value: _iconTier, items: const [DropdownMenuItem(value: 'gameSystem', child: Text('Game system')), DropdownMenuItem(value: 'gameSetting', child: Text('Game setting')), DropdownMenuItem(value: 'bookType', child: Text('Book type'))], onChanged: (v) => setState(() { _iconTier = v!; _iconSection = null; _iconPreviewPath = null; _iconSourcePath = null; _iconX = 0; _iconY = 0; _iconZoom = 1; })),
                  DropdownButton<String>(value: snap.data?.contains(_iconSection) == true ? _iconSection : null, hint: const Text('Choose section'), items: (snap.data ?? const []).map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(), onChanged: _selectIconSection),
                  if (_iconSection != null) ...[
                    _slider('Horizontal focus', _iconX, (v) => setState(() => _iconX = v), -1, 1),
                    _slider('Vertical focus', _iconY, (v) => setState(() => _iconY = v), -1, 1),
                    _slider('Zoom', _iconZoom, (v) => setState(() => _iconZoom = v), 1, 3),
                  ],
                  Wrap(spacing: 10, children: [
                    OutlinedButton.icon(onPressed: _busy || _iconSection == null ? null : _chooseCatalogIcon, icon: const Icon(Icons.image), label: const Text('Choose icon')),
                    FilledButton.icon(onPressed: _busy || _iconSourcePath == null ? null : _saveCatalogIcon, icon: const Icon(Icons.save), label: const Text('Save icon')),
                  ]),
                  if (_iconSection != null) TextButton(onPressed: _busy ? null : _removeCatalogIcon, child: const Text('Remove icon')),
                      ],
                    );
                    final preview = Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_iconSection == null)
                          const Text('Choose a section to preview its custom icon.')
                        else if (_iconPreviewPath == null ||
                            !File(_iconPreviewPath!).existsSync())
                          const Text('No saved icon for this section.')
                        else
                          ClipOval(
                            child: SizedBox(
                              width: 96,
                              height: 96,
                              child: ClipOval(
                                child: Transform.scale(
                                  scale: _iconZoom,
                                  child: Image.file(
                                    File(_iconPreviewPath!),
                                    width: 96,
                                    height: 96,
                                    fit: BoxFit.contain,
                                    alignment: Alignment(_iconX, _iconY),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                    return c.maxWidth >= 560
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: controls),
                              const SizedBox(width: 24),
                              Expanded(child: Center(child: preview)),
                            ],
                          )
                        : Column(
                            children: [
                              controls,
                              const SizedBox(height: 16),
                              Center(child: preview),
                            ],
                          );
                  },
                ),
              ),
            ),
            _Section(
              title: 'Database and recovery',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Active database'),
                  const SizedBox(height: 4),
                  SelectableText(
                    widget.controller.activeDatabasePath ?? 'None',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _newDatabase,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('New database'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _openDatabase,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open database'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _restore,
                        icon: const Icon(Icons.restore),
                        label: const Text('Restore backup'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                  await widget.controller.backups.createBackup(
                                    databasePath:
                                        widget.controller.database.databasePath,
                                    database: widget
                                        .controller.database.databaseHandle,
                                  );
                                }, success: 'Backup created.'),
                        icon: const Icon(Icons.save_as_outlined),
                        label: const Text('Back up now'),
                      ),
                      TextButton.icon(
                        onPressed: _busy ? null : _close,
                        icon: const Icon(Icons.close),
                        label: const Text('Close database'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Recent automatic backups',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (_backups.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('No backup snapshot has been created yet.'),
                    ),
                  ..._backups.take(6).map(
                        (backup) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.history),
                          title: Text(backup.uri.pathSegments.last),
                          subtitle: Text(
                            DateFormat.yMMMd().add_jm().format(
                                  backup.lastModifiedSync(),
                                ),
                          ),
                          trailing: TextButton(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                      () => widget.controller.restoreFromBackup(
                                        backup.path,
                                      ),
                                      success:
                                          'Backup restored into a new active database.',
                                    ),
                            child: const Text('Restore'),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      );
}

extension _SingleOrNull<T> on List<T> {
  T? get singleOrNull => length == 1 ? single : null;
}
