import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/app_controller.dart';
import '../services/catalog_bundle_service.dart';
import '../services/sync_coordinator.dart';
import '../services/sync_contract.dart';
import '../services/sync_metadata.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.onSyncRestore,
  });
  final AppController controller;
  final VoidCallback? onSyncRestore;

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

  Future<void> _cancelConnection() async {
    try {
      await widget.controller.cancelPendingConnection();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel connection: $error')),
        );
      }
    }
  }

  Future<void> _editDeviceName() async {
    final name = TextEditingController(text: widget.controller.deviceName);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name this device'),
        content: TextField(
          controller: name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Device name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await _run(
        () => widget.controller.setDeviceName(name.text),
        success: 'Device name saved.',
      );
    }
    name.dispose();
  }

  Future<void> _confirmTakeover() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Take over automatic sync?'),
        content: const Text(
          'This device will request ownership of automatic backups. If another device is online, it may continue until it next contacts cloud storage; takeover does not instantly disable an offline device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Take over'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(
        widget.controller.takeOverAutomaticSync,
        success: 'Automatic sync ownership request sent.',
      );
    }
  }

  Future<void> _syncNow() async {
    try {
      await widget.controller.syncNow();
    } on SyncDecisionRequired catch (decision) {
      if (!mounted) return;
      if (decision.result.classification == SyncClassification.unknownError) {
        throw StateError(
          'Sync status could not be checked. Retry without changing either catalog.',
        );
      }
      final localFingerprint = decision.localFingerprint ?? '';
      final choice = await showDialog<SyncConflictChoice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Catalogs differ'),
          content: const Text(
            'Choose which catalog to keep. Download replaces this device with the remote catalog. Upload replaces the remote catalog with this device. Cancel leaves both unchanged.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, SyncConflictChoice.cancel),
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(
                context,
                SyncConflictChoice.downloadReplaceLocal,
              ),
              child: const Text('Download and replace local'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                SyncConflictChoice.uploadReplaceRemote,
              ),
              child: const Text('Upload and replace remote'),
            ),
          ],
        ),
      );
      if (choice == null || choice == SyncConflictChoice.cancel) return;
      try {
        final restored = await widget.controller.resolveSyncDecision(
          choice,
          decision: decision.result,
          localFingerprint: localFingerprint,
        );
        if (restored && mounted) widget.onSyncRestore?.call();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not complete sync: $error')),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    final providerLabel =
        widget.controller.selectedProvider?.provider == 'onedrive'
        ? 'Microsoft OneDrive'
        : widget.controller.selectedProvider?.provider == 'dropbox'
        ? 'Dropbox'
        : 'Google Drive';
    final message =
        widget.controller.syncCoordinator.lastOutcome ==
            SyncOutcome.alreadySynced
        ? 'Already synced—no local changes.'
        : 'Catalog synced to $providerLabel.';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

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
    await _run(
      () => widget.controller.saveCatalogIcon(
        tier: _iconTier,
        sectionName: section,
        sourcePath: source,
        alignmentX: _iconX,
        alignmentY: _iconY,
        zoom: _iconZoom,
      ),
      success: 'Catalog icon saved.',
    );
    if (mounted) setState(() => _iconSourcePath = null);
    await _selectIconSection(section);
  }

  Future<void> _chooseCatalogIcon() async {
    if (_iconSection == null) return;
    final picked = await FilePicker.pickFiles(
      type: FileType.image,
      dialogTitle: 'Choose catalog icon',
    );
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
    final mapping = await widget.controller.database.getCatalogIcon(
      tier,
      value,
    );
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
    await _run(
      () => widget.controller.removeCatalogIcon(_iconTier, section),
      success: 'Catalog icon removed.',
    );
    if (mounted && _iconSection == section)
      setState(() {
        _iconPreviewPath = null;
        _iconSourcePath = null;
      });
  }

  Widget _slider(
    String label,
    double value,
    ValueChanged<double> onChanged,
    double min,
    double max,
  ) => Semantics(
    label: label,
    value: value.toStringAsFixed(2),
    child: Row(
      children: [
        SizedBox(width: 125, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: ((max - min) * 10).round(),
            label: value.toStringAsFixed(2),
            onChanged: onChanged,
          ),
        ),
      ],
    ),
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
    final name = TextEditingController(text: 'realmwise');
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

  Future<void> _exportDeviceBundle() async {
    final chosen = await FilePicker.saveFile(
      dialogTitle: 'Export portable device bundle',
      fileName: 'realmwise.realmwise',
      type: FileType.custom,
      allowedExtensions: const ['realmwise', 'zip'],
    );
    if (chosen == null) return;
    final output =
        chosen.toLowerCase().endsWith('.realmwise') ||
            chosen.toLowerCase().endsWith('.zip')
        ? chosen
        : '$chosen.realmwise';
    await _run(
      () => widget.controller.exportDeviceBundle(output),
      success: 'Portable device bundle exported to $output',
    );
  }

  Future<void> _restoreDeviceBundle() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['realmwise', 'zip'],
      dialogTitle: 'Choose portable device bundle',
    );
    final source = picked?.files.singleOrNull?.path;
    if (source == null || !mounted) return;
    late final BundleManifest manifest;
    try {
      manifest = await widget.controller.previewDeviceBundle(source);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Bundle is not valid: $error')));
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore portable bundle?'),
        content: Text(
          'Identity: ${manifest.catalogIdentity}\n'
          'Bundle date: ${manifest.createdAt}\n'
          'Database version: ${manifest.appVersion}\n'
          'Assets: ${manifest.assets.length}\n\n'
          'This will replace the active catalog. A recoverable pre-import backup will be created.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(
        () => widget.controller.restoreDeviceBundle(source),
        success: 'Portable device bundle imported; active catalog replaced.',
      );
    }
  }

  Future<void> _exportCsv() async {
    final chosen = await FilePicker.saveFile(
      dialogTitle: 'Export catalog as CSV',
      fileName: 'realmwise_export.csv',
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (chosen == null) return;
    final output = chosen.toLowerCase().endsWith('.csv')
        ? chosen
        : '$chosen.csv';
    await _run(
      () => widget.controller.exportDatabaseCsv(output),
      success: 'Catalog CSV exported to $output',
    );
  }

  Future<void> _importCsv() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      dialogTitle: 'Import catalog CSV',
      withData: false,
    );
    final source = picked?.files.singleOrNull?.path;
    if (source == null) return;
    await _run(() async {
      final csv = await File(source).readAsString();
      await widget.controller.importDatabaseCsv(csv);
    }, success: 'Catalog CSV imported.');
  }

  Future<void> _close() async {
    final route = DialogRoute<bool>(
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
    final yes = await Navigator.of(context).push(route);
    await route.completed;
    if (yes == true && mounted && widget.controller.isOpen) {
      await widget.controller.closeDatabase();
    }
  }

  Future<void> _downloadRemote() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _downloadRemoteConfirmed();
    } on SyncDecisionRequired catch (decision) {
      if (!mounted) return;
      if (decision.result.classification == SyncClassification.unknownError) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Sync status unavailable. Retry; nothing was changed.',
            ),
          ),
        );
        return;
      }
      final choice = await showDialog<SyncConflictChoice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Catalogs differ'),
          content: const Text(
            'Downloading replaces this device with the remote catalog. Upload replaces the remote catalog with this device. Cancel leaves both unchanged.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, SyncConflictChoice.cancel),
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(
                context,
                SyncConflictChoice.downloadReplaceLocal,
              ),
              child: const Text('Download and replace local'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                SyncConflictChoice.uploadReplaceRemote,
              ),
              child: const Text('Upload and replace remote'),
            ),
          ],
        ),
      );
      if (choice != null && choice != SyncConflictChoice.cancel) {
        try {
          final restored = await widget.controller.resolveSyncDecision(
            choice,
            decision: decision.result,
            localFingerprint: decision.localFingerprint ?? '',
          );
          if (restored && mounted) widget.onSyncRestore?.call();
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not download remote catalog: $error'),
              ),
            );
          }
          return;
        }
      }
      return;
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not download remote catalog: $error')),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadRemoteConfirmed() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Download remote catalog?'),
        content: const Text(
          'This replaces the active catalog. A recoverable pre-import backup will be created first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final restored = await widget.controller.downloadRemoteBundle();
      if (restored && mounted) widget.onSyncRestore?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Interface'),
              Tab(text: 'Local Database'),
              Tab(text: 'Cloud Sync'),
              Tab(text: 'Data Sources'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _tabContent(_interfaceSections()),
                _tabContent(_databaseSections()),
                _tabContent(_cloudSyncSections()),
                _tabContent(_dataSourceSections()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabContent(List<Widget> sections) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 800),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 22, 18, 44),
        children: sections,
      ),
    ),
  );

  List<Widget> _interfaceSections() => [
    _Section(
      title: 'Theme',
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
                    if (value) {
                      _run(() => widget.controller.setTheme(entry.key));
                    }
                  },
            avatar: CircleAvatar(backgroundColor: entry.value, radius: 10),
            label: Text(entry.key),
          );
        }).toList(),
      ),
    ),
    _Section(
      title: 'User Interface',
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Book type before game setting'),
        subtitle: Text(
          widget.controller.hierarchyOrder ==
                  CatalogHierarchyOrder.gameSystemBookTypeSetting
              ? 'Game System > Book Type > Game Setting'
              : 'Game System > Game Setting > Book Type',
        ),
        value:
            widget.controller.hierarchyOrder ==
            CatalogHierarchyOrder.gameSystemBookTypeSetting,
        onChanged: _busy
            ? null
            : (value) {
                final order = value
                    ? CatalogHierarchyOrder.gameSystemBookTypeSetting
                    : CatalogHierarchyOrder.gameSystemSettingBookType;
                _run(() => widget.controller.setHierarchyOrder(order));
              },
      ),
    ),
    _catalogIconsSection(),
  ];

  Widget _catalogIconsSection() => _Section(
    title: 'Custom Catalog Icons',
    child: FutureBuilder<List<String>>(
      future: widget.controller.database.listCatalogTierSections(_iconTier),
      builder: (context, snap) => LayoutBuilder(
        builder: (context, constraints) {
          final controls = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _iconTier,
                decoration: const InputDecoration(labelText: 'Icon category'),
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                    value: 'gameSystem',
                    child: Text('Game system'),
                  ),
                  DropdownMenuItem(
                    value: 'gameSetting',
                    child: Text('Game setting'),
                  ),
                  DropdownMenuItem(value: 'bookType', child: Text('Book type')),
                ],
                onChanged: (value) => setState(() {
                  _iconTier = value!;
                  _iconSection = null;
                  _iconPreviewPath = null;
                  _iconSourcePath = null;
                  _iconX = 0;
                  _iconY = 0;
                  _iconZoom = 1;
                }),
              ),
              DropdownButtonFormField<String>(
                initialValue: snap.data?.contains(_iconSection) == true
                    ? _iconSection
                    : null,
                decoration: const InputDecoration(labelText: 'Category'),
                isExpanded: true,
                items: (snap.data ?? const [])
                    .map(
                      (section) => DropdownMenuItem(
                        value: section,
                        child: Text(section),
                      ),
                    )
                    .toList(),
                onChanged: _selectIconSection,
              ),
              const SizedBox(height: 8),
              const Text(
                'Game systems and settings use a rounded-square frame; book types remain circular.',
              ),
              if (_iconSection != null) ...[
                _slider(
                  'Horizontal focus',
                  _iconX,
                  (value) => setState(() => _iconX = value),
                  -1,
                  1,
                ),
                _slider(
                  'Vertical focus',
                  _iconY,
                  (value) => setState(() => _iconY = value),
                  -1,
                  1,
                ),
                _slider(
                  'Zoom',
                  _iconZoom,
                  (value) => setState(() => _iconZoom = value),
                  1,
                  3,
                ),
              ],
              Wrap(
                spacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy || _iconSection == null
                        ? null
                        : _chooseCatalogIcon,
                    icon: const Icon(Icons.image),
                    label: const Text('Choose icon'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy || _iconSourcePath == null
                        ? null
                        : _saveCatalogIcon,
                    icon: const Icon(Icons.save),
                    label: const Text('Save icon'),
                  ),
                ],
              ),
              if (_iconSection != null)
                TextButton(
                  onPressed: _busy ? null : _removeCatalogIcon,
                  child: const Text('Remove icon'),
                ),
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
                ClipRRect(
                  borderRadius: BorderRadius.circular(
                    _iconTier == 'bookType' ? 48 : 14,
                  ),
                  child: SizedBox(
                    width: 96,
                    height: 96,
                    child: ClipRect(
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
          return constraints.maxWidth >= 560
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
  );

  List<Widget> _dataSourceSections() => [
    _Section(
      title: 'RPG Geek Data Enrichment',
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
                icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
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
  ];

  List<Widget> _databaseSections() => [
    _Section(
      title: 'Local Image Library',
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
    _deviceSyncSection(),
    _databaseRecoverySection(),
  ];

  List<Widget> _cloudSyncSections() => [
    _cloudSyncSection(),
    _Section(
      title: 'Include Personal Images/Catalog Icons',
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Include personal images and catalog icons'),
        subtitle: const Text(
          'Off by default. Turn this on only when you want images included in cloud bundles; mobile data may be used.',
        ),
        value: widget.controller.includePersonalImagesInBundles,
        onChanged: _busy
            ? null
            : widget.controller.setIncludePersonalImagesInBundles,
      ),
    ),
  ];

  Widget _cloudSyncSection() {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => _cloudSyncSectionContent(),
    );
  }

  Widget _cloudSyncSectionContent() {
    final metadata = widget.controller.syncMetadata;
    final providers = widget.controller.availableProviders;
    final selected = widget.controller.selectedProvider;
    final connected = widget.controller.providerSelectionLocked;
    final connectionPending = widget.controller.isConnectionPending;
    String label(SyncProvider p) => p.provider == 'onedrive'
        ? 'Microsoft OneDrive'
        : p.provider == 'dropbox'
        ? 'Dropbox'
        : 'Google Drive';
    final status = providers.isEmpty
        ? 'Cloud sync is not configured on this build.'
        : connectionPending
        ? 'Connecting to Dropbox… (not connected)'
        : connected
        ? 'Connected provider: ${selected == null ? 'Unknown' : label(selected)} (${metadata?.accountDisplayName ?? metadata?.accountId ?? 'account unavailable'})'
        : metadata?.state.label ?? 'Not connected';
    final progress = widget.controller.syncProgress;
    final statusSection = _Section(
      title: 'Sync Status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status),
          if (metadata?.state != null &&
              metadata!.state != SyncState.notConnected)
            Text('Status: ${metadata.state.label}'),
          if (metadata?.updatedAt != null && metadata!.state == SyncState.ready)
            Text(
              'Last successful sync: ${DateFormat.yMMMd().add_jm().format(metadata.updatedAt!.toLocal())}',
            ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress.fraction),
            const SizedBox(height: 4),
            Text('${progress.phase} (${(progress.fraction * 100).round()}%)'),
            const Text(
              'Cancel stops at the next safe boundary; an in-flight provider request may finish before cancellation takes effect.',
            ),
          ],
          if (metadata?.error != null)
            Text(
              'Last sync failed. Retry when online; re-authorize if access expired. Check quota, resolve conflicts, or reconnect if the remote bundle is invalid.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
    final automaticSection = _Section(
      title: 'Automatic sync',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Automatic sync'),
            subtitle: Text(
              widget.controller.automaticSyncEnabled
                  ? (widget.controller.automaticSyncOwnershipValid
                        ? 'This device owns automatic sync.'
                        : 'Waiting for cloud ownership confirmation; uploads are paused.')
                  : 'Off. Manual Sync now remains available.',
            ),
            value: widget.controller.automaticSyncEnabled,
            onChanged: _busy || !connected
                ? null
                : (value) => _run(
                    () => value
                        ? widget.controller.setAutomaticSyncEnabled(true)
                        : widget.controller.setAutomaticSyncEnabled(false),
                  ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              widget.controller.deviceName.isEmpty
                  ? 'This device'
                  : widget.controller.deviceName,
            ),
            subtitle: Text(
              'Device ID: ${widget.controller.deviceId.isEmpty ? 'Unavailable' : widget.controller.deviceId}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit device name',
              onPressed: _busy ? null : _editDeviceName,
            ),
          ),
          if (connected && !widget.controller.automaticSyncOwnershipValid)
            OutlinedButton.icon(
              onPressed: _busy || !connected ? null : _confirmTakeover,
              icon: const Icon(Icons.switch_account_outlined),
              label: const Text('Take over automatic sync'),
            ),
          if (widget.controller.automaticSyncLastSuccess != null)
            Text(
              'Last automatic sync: ${DateFormat.yMMMd().add_jm().format(widget.controller.automaticSyncLastSuccess!.toLocal())}',
            ),
          if (widget.controller.automaticSyncError != null)
            Text(
              widget.controller.automaticSyncError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 6),
          const Text(
            'Automatic sync is a single-device backup with controlled handoff, not realtime multi-device collaboration.',
          ),
        ],
      ),
    );
    final providerSection = _Section(
      title: 'Sync Providers',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (providers.isNotEmpty)
            Wrap(
              spacing: 8,
              children: providers
                  .map(
                    (provider) => ChoiceChip(
                      label: Text(label(provider)),
                      selected: selected?.provider == provider.provider,
                      onSelected: connected || connectionPending || _busy
                          ? null
                          : (_) => _run(
                              () => widget.controller.selectProvider(provider),
                            ),
                    ),
                  )
                  .toList(),
            ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed:
                    _busy || connectionPending || selected == null || connected
                    ? null
                    : () => _run(
                        selected.provider == 'onedrive'
                            ? widget.controller.connectOneDrive
                            : selected.provider == 'dropbox'
                            ? widget.controller.connectDropbox
                            : widget.controller.connectGoogleDrive,
                        success: '${label(selected)} connected.',
                      ),
                icon: const Icon(Icons.login),
                label: Text(
                  selected == null ? 'Connect' : 'Connect ${label(selected)}',
                ),
              ),
              if (connectionPending)
                OutlinedButton.icon(
                  onPressed: _cancelConnection,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel connection'),
                ),
              OutlinedButton.icon(
                onPressed:
                    _busy ||
                        connectionPending ||
                        !connected ||
                        widget.controller.isSyncing
                    ? null
                    : () => _run(
                        widget.controller.disconnectGoogleDrive,
                        success: 'Disconnected.',
                      ),
                icon: const Icon(Icons.logout),
                label: const Text('Disconnect'),
              ),
            ],
          ),
        ],
      ),
    );
    final infoSection = _Section(
      title: 'Sync Information',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _busy || !connected || widget.controller.isSyncing
                    ? null
                    : () => _run(_syncNow),
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
              ),
              if (widget.controller.isSyncing)
                OutlinedButton.icon(
                  onPressed: widget.controller.cancelSync,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Cancel sync'),
                ),
              if (metadata?.error != null)
                TextButton.icon(
                  onPressed: _busy || !connected ? null : () => _run(_syncNow),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              OutlinedButton.icon(
                onPressed: _busy || !connected ? null : _downloadRemote,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Download remote'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Sync uploads a portable catalog bundle. Disconnect removes local credentials and settings only; remote files are not deleted.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Cloud Sync stores bundles in an isolated Realmwise section. The application cannot access your other files. A bundle contains catalog data and, only when enabled, selected images; it does not upload unrelated personal data.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Remote retention is provider-native: the current bundle is retained, and any prior version history is kept according to the connected provider\'s limits and policies.',
          ),
        ],
      ),
    );
    // Keep every Cloud Sync card aligned to the tab's available content width.
    // Without an explicit width, the cards can size themselves to their
    // individual contents when the surrounding tab is centered.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: double.infinity, child: statusSection),
        SizedBox(width: double.infinity, child: automaticSection),
        SizedBox(width: double.infinity, child: providerSection),
        SizedBox(width: double.infinity, child: infoSection),
      ],
    );
  }

  Widget _deviceSyncSection() => _Section(
    title: 'Manual Device Sync',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include uploaded images and catalog icons'),
          subtitle: const Text(
            'Personal files are excluded by default. Turn this on to copy them into sync backup files.',
          ),
          value: widget.controller.includePersonalImagesInBundles,
          onChanged: _busy
              ? null
              : (value) => _run(
                  () => widget.controller.setIncludePersonalImagesInBundles(
                    value,
                  ),
                ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _exportDeviceBundle,
              icon: const Icon(Icons.archive_outlined),
              label: const Text('Export device bundle'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _restoreDeviceBundle,
              icon: const Icon(Icons.unarchive_outlined),
              label: const Text('Restore device bundle'),
            ),
            const Text(
              'Bundles contain catalog data only; API keys, image folders, and device preferences are excluded.',
            ),
          ],
        ),
      ],
    ),
  );

  Widget _databaseRecoverySection() {
    final validBackups = _backups
        .where((backup) => backupLastModifiedForSettings(backup) != null)
        .toList();
    return _Section(
      title: 'Database and Recovery',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Active database'),
          const SizedBox(height: 4),
          SelectableText(widget.controller.activeDatabasePath ?? 'None'),
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
                          databasePath: widget.controller.database.databasePath,
                          database: widget.controller.database.databaseHandle,
                        );
                      }, success: 'Backup created.'),
                icon: const Icon(Icons.save_as_outlined),
                label: const Text('Back up now'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _exportCsv,
                icon: const Icon(Icons.table_view_outlined),
                label: const Text('Export CSV'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _importCsv,
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('Import CSV'),
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
          if (validBackups.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No backup snapshot has been created yet.'),
            ),
          ...validBackups
              .map(
                (backup) => (
                  backup: backup,
                  modified: backupLastModifiedForSettings(backup),
                ),
              )
              .where((entry) => entry.modified != null)
              .take(6)
              .map((entry) {
                final backup = entry.backup;
                final modified = entry.modified!;
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.history),
                  title: Text(backup.uri.pathSegments.last),
                  subtitle: Text(DateFormat.yMMMd().add_jm().format(modified)),
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
                );
              }),
        ],
      ),
    );
  }
}

DateTime? backupLastModifiedForSettings(File backup) {
  try {
    if (!backup.existsSync()) return null;
    return backup.lastModifiedSync();
  } on FileSystemException {
    return null;
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
