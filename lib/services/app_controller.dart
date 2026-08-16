import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database_service.dart';
import '../models/catalog_models.dart';
import 'backup_service.dart';
import 'catalog_bundle_service.dart';
import 'catalog_service.dart';
import 'external_catalog_service.dart';
import 'export_service.dart';
import 'image_storage_service.dart';
import 'import_service.dart';
import 'google_drive_sync.dart';
import 'onedrive_sync.dart';
import 'dropbox_sync.dart';
import 'secure_storage_service.dart';
import 'sync_contract.dart';
import 'sync_coordinator.dart';
import 'sync_metadata.dart';

enum CatalogHierarchyOrder {
  gameSystemSettingBookType,
  gameSystemBookTypeSetting,
}

/// Application session state: selected database, theme preference, and services.
class AppController extends ChangeNotifier {
  AppController({
    TokenStorage? tokenStorage,
    this.imageRootPathOverride,
    SyncProvider? syncProvider,
    SyncProvider? googleDriveProvider,
    SyncProvider? oneDriveProvider,
    SyncProvider? dropboxProvider,
  }) : database = DatabaseService(),
       _http = http.Client(),
       backups = BackupService(),
       _tokenStorage = tokenStorage ?? SecureStorageService(),
       _providers = {
         if (googleDriveProvider != null) 'google_drive': googleDriveProvider,
         if (oneDriveProvider != null) 'onedrive': oneDriveProvider,
         if (dropboxProvider != null) 'dropbox': dropboxProvider,
         if (syncProvider != null) syncProvider.provider: syncProvider,
       };

  final DatabaseService database;
  final BackupService backups;
  final ExportService exporter = ExportService();
  final CatalogBundleService bundles = CatalogBundleService();
  late final ImportService importer = ImportService(database);
  late final ImageStorageService imageStorage = ImageStorageService(_http);
  late final CatalogService catalog = CatalogService(
    database: database,
    images: imageStorage,
  );
  late final ExternalCatalogService lookup = ExternalCatalogService(_http);
  final http.Client _http;
  final TokenStorage _tokenStorage;

  /// Test seam for avoiding platform path providers; persisted DB settings win.
  final String? imageRootPathOverride;
  final Map<String, SyncProvider> _providers;
  SyncProvider? _selectedProvider;
  SyncProvider? get syncProvider => _selectedProvider;
  String get syncProviderName => _selectedProvider?.provider ?? 'none';
  List<SyncProvider> get availableProviders =>
      _providers.values.toList(growable: false);
  SyncProvider? get selectedProvider => _selectedProvider;
  bool get providerSelectionLocked => syncCoordinator.isConnected;

  Future<void> selectProvider(SyncProvider? provider) async {
    if (syncCoordinator.isConnected)
      throw StateError('Disconnect before changing sync provider.');
    if (provider != null && !_providers.values.contains(provider)) {
      throw StateError('Sync provider is not available.');
    }
    _selectedProvider = provider;
    notifyListeners();
  }

  late SyncCoordinator syncCoordinator;
  SyncMetadata? syncMetadata;

  bool loading = true;
  String? error;
  String seedName = 'Dragon red';
  CatalogHierarchyOrder hierarchyOrder =
      CatalogHierarchyOrder.gameSystemSettingBookType;
  bool includePersonalImagesInBundles = false;

  // Work IDs observed after opening a database are the session baseline. Any
  // IDs appearing later are kept in memory only so the catalog can label them.
  final Set<int> _sessionBaselineWorkIds = <int>{};
  final Set<int> sessionNewWorkIds = <int>{};

  bool get isOpen => database.isOpen;
  String? get activeDatabasePath => isOpen ? database.databasePath : null;

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      syncCoordinator = SyncCoordinator(
        metadataStorage: SharedPreferencesSyncMetadataStorage(prefs),
      );
      _selectedProvider ??= _providers.isEmpty ? null : _providers.values.first;
      includePersonalImagesInBundles =
          prefs.getBool('include_personal_images_in_bundles') ?? false;
      final saved = prefs.getString('last_database_path');
      if (saved != null && await File(saved).exists()) {
        await openDatabase(saved, remember: false);
      } else {
        final documents = await getApplicationDocumentsDirectory();
        final current = path.join(documents.path, 'my_realmwise.db');
        final legacy = path.join(documents.path, 'my_rpg_catalog.db');
        if (!await File(current).exists() && await File(legacy).exists()) {
          await openDatabase(legacy, remember: false);
        } else {
          await createDatabase('my_realmwise', remember: false);
        }
      }
    } catch (exception) {
      error = exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> createDatabase(
    String requestedName, {
    bool remember = true,
  }) async {
    final documents = await getApplicationDocumentsDirectory();
    final safe = requestedName.trim().replaceAll(
      RegExp(r'[^A-Za-z0-9_-]+'),
      '_',
    );
    if (safe.isEmpty) throw ArgumentError('Enter a database name.');
    await openDatabase(
      path.join(documents.path, '$safe.db'),
      remember: remember,
    );
  }

  Future<void> openDatabase(String databasePath, {bool remember = true}) async {
    // A connection belongs to one catalog identity. Do not carry a live
    // provider/session into a different database, but retain its saved setup
    // so reopening it can restore normally.
    // Reopening can replace the catalog contents at the same path (for
    // example, portable bundle restore). A live coordinator session must not
    // outlive that catalog swap; persisted metadata below may restore it when
    // the imported catalog has the same identity.
    syncCoordinator.resetRuntime();
    syncMetadata = null;
    _selectedProvider = null;
    error = null;
    await backups.stop();
    await database.open(databasePath);
    final catalogIdentity = await database.ensureCatalogIdentity();
    syncMetadata = await syncCoordinator.metadataStorage.read(catalogIdentity);
    syncCoordinator.metadata = syncMetadata;
    final savedSync = syncMetadata;
    final provider = savedSync?.provider == null
        ? null
        : _providers[savedSync!.provider!];
    _selectedProvider = provider;
    if (savedSync != null &&
        provider != null &&
        (provider is GoogleDriveProvider ||
            provider is OneDriveProvider ||
            provider is DropboxProvider)) {
      final restored = provider is GoogleDriveProvider
          ? await provider.restoreSession()
          : provider is OneDriveProvider
          ? await provider.restoreSession()
          : await (provider as DropboxProvider).restoreSession();
      if (restored != null) {
        try {
          await syncCoordinator.restore(provider, restored, savedSync);
          syncMetadata = syncCoordinator.metadata;
        } catch (_) {
          syncMetadata = savedSync;
        }
      }
    }
    await _migrateRpgGeekToken(catalogIdentity);
    _sessionBaselineWorkIds
      ..clear()
      ..addAll(
        (await database.listRecords())
            .map((record) => record.work.id)
            .whereType<int>(),
      );
    sessionNewWorkIds.clear();
    final imageFolder = await database.getSetting('image_folder');
    await imageStorage.initialize(imageFolder ?? imageRootPathOverride);
    seedName = await database.getSetting('theme_seed') ?? 'Dragon red';
    final savedHierarchy = await database.getSetting('catalog_hierarchy_order');
    hierarchyOrder = savedHierarchy == 'gameSystemBookTypeSetting'
        ? CatalogHierarchyOrder.gameSystemBookTypeSetting
        : CatalogHierarchyOrder.gameSystemSettingBookType;
    await backups.start(
      databasePath: database.databasePath,
      database: database.databaseHandle,
    );
    if (remember) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_database_path', database.databasePath);
    }
    notifyListeners();
  }

  Future<void> _migrateRpgGeekToken(String catalogIdentity) async {
    final secureKey = _storageKey(catalogIdentity);
    final secure = await _tokenStorage.read(secureKey);
    final legacy = (await database.getLegacyRpgGeekKey())?.trim();
    if (secure == null && legacy != null && legacy.isNotEmpty) {
      await _tokenStorage.write(secureKey, legacy);
    }
    if (legacy != null && legacy.isNotEmpty) {
      await database.deleteLegacyRpgGeekKey();
    }
    await backups.scrubLegacyTokens(database.databasePath);
  }

  Future<void> closeDatabase() async {
    await backups.stop();
    await database.close();
    syncCoordinator.resetRuntime();
    syncMetadata = null;
    _selectedProvider = null;
    _sessionBaselineWorkIds.clear();
    sessionNewWorkIds.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('last_database_path');
    notifyListeners();
  }

  Future<void> _connect(SyncProvider? provider) async {
    if (provider == null) {
      throw StateError(
        'Selected sync provider is not configured on this device.',
      );
    }
    if (!database.isOpen) throw StateError('Open a catalog first.');
    final identity = await database.ensureCatalogIdentity();
    try {
      syncMetadata = await syncCoordinator.connect(provider, identity);
      if (syncMetadata!.state == SyncState.connectedUnconfigured &&
          syncCoordinator.session != null &&
          (provider is GoogleDriveProvider ||
              provider is OneDriveProvider ||
              provider is DropboxProvider)) {
        final target = provider is GoogleDriveProvider
            ? await provider.ensureBundleTarget(syncCoordinator.session!)
            : provider is OneDriveProvider
            ? await provider.ensureBundleTarget(syncCoordinator.session!)
            : await (provider as DropboxProvider).ensureBundleTarget(
                syncCoordinator.session!,
              );
        await syncCoordinator.configureTarget(target);
        syncMetadata = syncCoordinator.metadata;
      }
    } catch (error) {
      await syncCoordinator.failConnection(error);
      syncMetadata = syncCoordinator.metadata;
      notifyListeners();
      rethrow;
    }
    _selectedProvider = provider;
    notifyListeners();
  }

  Future<void> connectGoogleDrive() => _connect(_providers['google_drive']);
  Future<void> connectOneDrive() => _connect(_providers['onedrive']);
  Future<void> connectDropbox() => _connect(_providers['dropbox']);

  Future<void> disconnectOneDrive() => disconnectGoogleDrive();

  Future<void> syncNow() async {
    if (!database.isOpen) throw StateError('Open a catalog first.');
    final identity = await database.ensureCatalogIdentity();
    final temporary = await getTemporaryDirectory();
    final bundlePath = path.join(
      temporary.path,
      'realmwise-sync-${DateTime.now().microsecondsSinceEpoch}.realmwise',
    );
    try {
      await exportDeviceBundle(bundlePath);
      final manifest = await bundles.validateBundle(bundlePath);
      final classification = await syncCoordinator.classify(
        manifest.contentFingerprint,
      );
      if (classification.classification == SyncClassification.divergent ||
          classification.classification == SyncClassification.remoteOnly ||
          classification.classification == SyncClassification.unknownError) {
        throw SyncDecisionRequired(
          classification,
          localFingerprint: manifest.contentFingerprint,
        );
      }
      syncMetadata = await syncCoordinator.sync(
        Uint8List.fromList(await File(bundlePath).readAsBytes()),
        localFingerprint: manifest.contentFingerprint,
      );
      assert(syncMetadata?.catalogIdentity == identity);
      notifyListeners();
    } finally {
      final file = File(bundlePath);
      if (await file.exists()) await file.delete();
    }
  }

  /// Applies a choice made in the conflict dialog. Every replacement creates
  /// a recoverable local snapshot before transfer or database swap.
  Future<void> resolveSyncDecision(
    SyncConflictChoice choice, {
    required SyncClassificationResult decision,
    required String localFingerprint,
  }) async {
    if (choice == SyncConflictChoice.cancel) return;
    if (!database.isOpen) throw StateError('Open a catalog first.');
    final temporary = await getTemporaryDirectory();
    final bundlePath = path.join(
      temporary.path,
      'realmwise-conflict-${DateTime.now().microsecondsSinceEpoch}.realmwise',
    );
    try {
      Future<void> localBackup() => backups.createBackup(
        databasePath: database.databasePath,
        database: database.databaseHandle,
      );
      if (choice == SyncConflictChoice.downloadReplaceLocal) {
        if (decision.remote == null)
          throw StateError('Remote metadata unavailable.');
        await exportDeviceBundle(bundlePath);
        final now = await bundles.validateBundle(bundlePath);
        if (now.contentFingerprint != localFingerprint) {
          throw StateError(
            'The local catalog changed; review the conflict again.',
          );
        }
        await downloadRemoteBundle(
          expectedRemote: decision.remote,
          expectedLocalFingerprint: localFingerprint,
          backup: localBackup,
        );
      } else {
        await exportDeviceBundle(bundlePath);
        final manifest = await bundles.validateBundle(bundlePath);
        final currentFingerprint = manifest.contentFingerprint;
        if (decision.remote == null ||
            currentFingerprint == null ||
            currentFingerprint != localFingerprint) {
          throw StateError(
            'The local catalog changed; review the conflict again.',
          );
        }
        // Preserve the observed remote bytes locally before allowing a remote
        // overwrite. A DB backup alone cannot recover the remote catalog.
        final remote = await syncCoordinator.download(
          expectedRemote: decision.remote,
        );
        final remotePath = path.join(
          path.dirname(database.databasePath),
          'backups',
          '${path.basenameWithoutExtension(database.databasePath)}_pre-remote-overwrite-${DateTime.now().microsecondsSinceEpoch}.realmwise',
        );
        final remoteTemp = '$remotePath.tmp';
        await Directory(path.dirname(remotePath)).create(recursive: true);
        await File(remoteTemp).writeAsBytes(remote.payload, flush: true);
        try {
          await bundles.validateBundle(remoteTemp);
          await File(remoteTemp).rename(remotePath);
        } catch (_) {
          final f = File(remoteTemp);
          if (await f.exists()) await f.delete();
          rethrow;
        }
        await syncCoordinator.resolveConflict(
          choice,
          currentLocalFingerprint: currentFingerprint,
          expectedLocalFingerprint: localFingerprint,
          observedRemote: decision.remote!,
          payload: Uint8List.fromList(await File(bundlePath).readAsBytes()),
          payloadFingerprint: currentFingerprint,
          backup: localBackup,
        );
        syncMetadata = syncCoordinator.metadata;
        notifyListeners();
      }
    } finally {
      final file = File(bundlePath);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> downloadRemoteBundle({
    SyncRemoteMetadata? expectedRemote,
    String? expectedLocalFingerprint,
    Future<void> Function()? backup,
  }) async {
    if (!database.isOpen) throw StateError('Open a catalog first.');
    final temporary = await getTemporaryDirectory();
    SyncRemoteMetadata? discoveredRemote = expectedRemote;
    if (expectedRemote == null) {
      final checkPath = path.join(
        temporary.path,
        'realmwise-check-${DateTime.now().microsecondsSinceEpoch}.realmwise',
      );
      try {
        await exportDeviceBundle(checkPath);
        final local = await bundles.validateBundle(checkPath);
        final decision = await syncCoordinator.classify(
          local.contentFingerprint,
        );
        if (decision.classification == SyncClassification.localOnly ||
            decision.classification == SyncClassification.divergent ||
            decision.classification == SyncClassification.unknownError) {
          throw SyncDecisionRequired(decision);
        }
        discoveredRemote = decision.remote;
      } finally {
        final f = File(checkPath);
        if (await f.exists()) await f.delete();
      }
    }
    final bundlePath = path.join(
      temporary.path,
      'realmwise-remote-${DateTime.now().microsecondsSinceEpoch}.realmwise',
    );
    try {
      SyncDownloadResult? result;
      BundleManifest? manifest;
      const maxBundleReadRetries = 3;
      for (var attempt = 0; attempt < maxBundleReadRetries; attempt++) {
        try {
          result = await syncCoordinator.download(
            expectedRemote: discoveredRemote,
          );
          await File(bundlePath).writeAsBytes(result.payload, flush: true);
          manifest = await previewDeviceBundle(bundlePath);
          break;
        } catch (error) {
          // Only an invalid bundle can be caused by OneDrive's short
          // read-after-write window. Authentication, transport, missing
          // targets, conflicts, and local-change guards must surface at once.
          if (error is! FormatException) rethrow;
          if (attempt == maxBundleReadRetries - 1) rethrow;
          await Future<void>.delayed(
            Duration(milliseconds: 100 * (1 << attempt)),
          );
        }
      }
      if (result == null || manifest == null) {
        throw StateError('Remote bundle could not be read.');
      }
      if (expectedLocalFingerprint != null) {
        final checkPath = path.join(
          temporary.path,
          'realmwise-final-check-${DateTime.now().microsecondsSinceEpoch}.realmwise',
        );
        try {
          await exportDeviceBundle(checkPath);
          final current = await bundles.validateBundle(checkPath);
          if (current.contentFingerprint != expectedLocalFingerprint) {
            throw StateError(
              'The local catalog changed; review the conflict again.',
            );
          }
        } finally {
          final check = File(checkPath);
          if (await check.exists()) await check.delete();
        }
      }
      if (backup != null) await backup();
      await restoreDeviceBundle(bundlePath);
      await syncCoordinator.commitDownload(
        result.metadata,
        localFingerprint: manifest.contentFingerprint,
      );
      syncMetadata = syncCoordinator.metadata;
      notifyListeners();
    } finally {
      final file = File(bundlePath);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> disconnectGoogleDrive() async {
    final provider = _selectedProvider;
    if (provider is GoogleDriveProvider) await provider.clearCredentials();
    if (provider is OneDriveProvider) await provider.clearCredentials();
    if (provider is DropboxProvider) await provider.clearCredentials();
    await syncCoordinator.disconnect();
    syncMetadata = null;
    _selectedProvider = null;
    notifyListeners();
  }

  Future<void> restoreFromBackup(String backupFile) async {
    final documents = await getApplicationDocumentsDirectory();
    final name = 'restored_${DateTime.now().millisecondsSinceEpoch}.db';
    final target = path.join(documents.path, name);
    await File(backupFile).copy(target);
    await openDatabase(target);
  }

  Future<void> exportDeviceBundle(String outputPath) => bundles.exportBundle(
    database: database,
    outputPath: outputPath,
    imageRootPath: imageStorage.rootPath,
    includePersonalImages: includePersonalImagesInBundles,
  );

  Future<void> setIncludePersonalImagesInBundles(bool value) async {
    includePersonalImagesInBundles = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('include_personal_images_in_bundles', value);
    notifyListeners();
  }

  Future<void> restoreDeviceBundle(String bundlePath) async {
    await bundles.validateBundle(bundlePath);
    if (!database.isOpen) throw StateError('No active database to replace.');
    final active = database.databasePath;
    final staged =
        '$active.portable-import-${DateTime.now().microsecondsSinceEpoch}.tmp';
    final backup = path.join(
      path.dirname(active),
      'backups',
      '${path.basenameWithoutExtension(active)}_pre-import-${DateTime.now().microsecondsSinceEpoch}.backup.db',
    );
    final importImageRoot = path.join(
      imageStorage.rootPath,
      'import-staging-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await bundles.extractDatabase(
        bundlePath,
        staged,
        imageRootPath: importImageRoot,
      );
    } catch (_) {
      final partial = File(staged);
      if (await partial.exists()) await partial.delete();
      final importedAssets = Directory(importImageRoot);
      if (await importedAssets.exists()) {
        await importedAssets.delete(recursive: true);
      }
      rethrow;
    }
    try {
      await _quiesceForBundleSwap();
    } catch (_) {
      try {
        if (!database.isOpen) await openDatabase(active);
      } catch (_) {}
      final partial = File(staged);
      if (await partial.exists()) await partial.delete();
      final importedAssets = Directory(importImageRoot);
      if (await importedAssets.exists())
        await importedAssets.delete(recursive: true);
      rethrow;
    }
    var swapped = false;
    var committed = false;
    var originalMoved = false;
    try {
      await Directory(path.dirname(backup)).create(recursive: true);
      await File(active).copy(backup);
      await File(active).rename('$backup.swap');
      originalMoved = true;
      await File(staged).rename(active);
      swapped = true;
      await openDatabase(active);
      if (await catalog.rehydrateMissingImages()) notifyListeners();
      committed = true;
    } catch (_) {
      try {
        await database.close();
        if (originalMoved) {
          final current = File(active);
          if (await current.exists()) await current.delete();
          final old = File('$backup.swap');
          if (await old.exists()) {
            await old.rename(active);
          } else if (await File(backup).exists()) {
            await File(backup).copy(active);
          }
        }
        await openDatabase(active);
      } catch (_) {}
      rethrow;
    } finally {
      final stagedFile = File(staged);
      if (await stagedFile.exists()) await stagedFile.delete();
      final old = File('$backup.swap');
      if (await old.exists() && swapped) await old.delete();
      if (!committed) {
        final importedAssets = Directory(importImageRoot);
        if (await importedAssets.exists()) {
          await importedAssets.delete(recursive: true);
        }
      }
    }
  }

  /// Validates an import without mutating the active catalog.
  Future<BundleManifest> previewDeviceBundle(String bundlePath) =>
      bundles.validateBundle(bundlePath);

  Future<void> _quiesceForBundleSwap() async {
    await backups.stop();
    await database.close();
  }

  Future<void> setImageFolder(String folder) async {
    await imageStorage.initialize(folder);
    await database.setSetting('image_folder', imageStorage.rootPath);
    notifyListeners();
  }

  Future<void> setTheme(String name) async {
    seedName = name;
    await database.setSetting('theme_seed', name);
    notifyListeners();
  }

  Future<void> setHierarchyOrder(CatalogHierarchyOrder order) async {
    hierarchyOrder = order;
    if (database.isOpen) {
      await database.setSetting(
        'catalog_hierarchy_order',
        order == CatalogHierarchyOrder.gameSystemBookTypeSetting
            ? 'gameSystemBookTypeSetting'
            : 'gameSystemSettingBookType',
      );
    }
    notifyListeners();
  }

  Future<void> saveCatalogIcon({
    required String tier,
    required String sectionName,
    required String sourcePath,
    double alignmentX = 0,
    double alignmentY = 0,
    double zoom = 1,
  }) async {
    final old = await database.getCatalogIcon(tier, sectionName);
    final local = await imageStorage.importCatalogIcon(
      sourcePath: sourcePath,
      tier: tier,
      sectionName: sectionName,
    );
    try {
      await database.upsertCatalogIcon(
        CatalogIconMapping(
          tier: tier,
          sectionName: sectionName,
          localPath: local,
          alignmentX: alignmentX,
          alignmentY: alignmentY,
          zoom: zoom,
        ),
      );
    } catch (_) {
      await _deleteManagedIcon(local);
      rethrow;
    }
    if (old != null && old.localPath != local)
      await _deleteManagedIcon(old.localPath);
  }

  Future<void> removeCatalogIcon(String tier, String sectionName) async {
    final old = await database.getCatalogIcon(tier, sectionName);
    await database.removeCatalogIcon(tier, sectionName);
    if (old != null) await _deleteManagedIcon(old.localPath);
  }

  Future<void> _deleteManagedIcon(String filePath) async {
    try {
      final root = path.normalize(imageStorage.rootPath);
      final target = path.normalize(filePath);
      if (!path.isWithin(root, target)) return;
      final mappings = await database.listCatalogIcons();
      if (mappings.any((m) => path.normalize(m.localPath) == target)) return;
      final file = File(target);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  String _storageKey(String identity) => 'rpggeek_api_key:$identity';

  String get _legacyPathStorageKey {
    if (!database.isOpen) throw StateError('No database is currently open.');
    return 'rpggeek_api_key:${path.normalize(database.databasePath)}';
  }

  Future<String> rpgGeekKey() async {
    final identity = await database.ensureCatalogIdentity();
    final storageKey = _storageKey(identity);
    final secure = await _tokenStorage.read(storageKey);
    if (secure != null) {
      // Remove any stale plaintext value left by an interrupted migration.
      await database.deleteLegacyRpgGeekKey();
      return secure;
    }
    final previous = await _tokenStorage.read(_legacyPathStorageKey);
    if (previous != null) {
      await _tokenStorage.write(storageKey, previous);
      await _tokenStorage.delete(_legacyPathStorageKey);
      return previous;
    }
    final legacy = (await database.getLegacyRpgGeekKey())?.trim();
    if (legacy == null || legacy.isEmpty) return '';
    await _tokenStorage.write(storageKey, legacy);
    await database.deleteLegacyRpgGeekKey();
    return legacy;
  }

  Future<void> setRpgGeekKey(String key) async {
    final identity = await database.ensureCatalogIdentity();
    final storageKey = _storageKey(identity);
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _tokenStorage.delete(storageKey);
    } else {
      await _tokenStorage.write(storageKey, trimmed);
    }
    await _tokenStorage.delete(_legacyPathStorageKey);
    await database.deleteLegacyRpgGeekKey();
  }

  Future<void> exportDatabaseCsv(String outputPath) async {
    if (!database.isOpen) throw StateError('No database is currently open.');
    final records = await database.listRecords();
    final timestamps = await database.workTimestamps();
    await exporter.exportRecords(
      records: records,
      outputPath: outputPath,
      timestampsByWorkId: timestamps,
    );
  }

  Future<void> importDatabaseCsv(String csv) async {
    if (!database.isOpen) throw StateError('No database is currently open.');
    final before = (await database.listRecords())
        .map((record) => record.work.id)
        .whereType<int>()
        .toSet();
    await importer.importCsv(csv);
    final after = await database.listRecords();
    sessionNewWorkIds.addAll(
      after
          .map((record) => record.work.id)
          .whereType<int>()
          .where((id) => !before.contains(id)),
    );
    notifyListeners();
  }

  /// Records IDs that appeared after the database was opened (for example,
  /// from the Add book flow). This state is intentionally not persisted.
  void observeCatalogRecords(Iterable<CatalogRecord> records) {
    sessionNewWorkIds.addAll(
      records
          .map((record) => record.work.id)
          .whereType<int>()
          .where((id) => !_sessionBaselineWorkIds.contains(id)),
    );
  }

  /// Clears the session-only NEW marker for a work once it is selected.
  void clearSessionNewWork(int? workId) {
    if (workId != null && sessionNewWorkIds.remove(workId)) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(backups.stop());
    unawaited(database.close());
    _http.close();
    super.dispose();
  }
}
