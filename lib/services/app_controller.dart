import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
import 'sync_debug.dart';
import 'diagnostic_logging.dart';
import 'diagnostic_bundle_service.dart';
import '../theme/app_theme.dart';

enum CatalogHierarchyOrder {
  gameSystemSettingBookType,
  gameSystemBookTypeSetting,
}

/// Returns a bounded, display-safe default name derived from a device host
/// name. The internal device ID remains a random stable identity for leases.
String? defaultDeviceNameForHostname(String hostname) {
  final normalized = hostname.trim().replaceAll(
    RegExp(r'[^A-Za-z0-9_-]+'),
    '-',
  );
  final compact = normalized.replaceAll(RegExp(r'-{2,}'), '-');
  if (compact.isEmpty) return null;
  final trimmed = compact
      .replaceFirst(RegExp(r'^-+'), '')
      .replaceFirst(RegExp(r'-+$'), '');
  if (trimmed.isEmpty) return null;
  return trimmed.length > 12 ? trimmed.substring(0, 12) : trimmed;
}

class _InMemorySyncMetadataStorage implements SyncMetadataStorage {
  final Map<String, SyncMetadata> _values = <String, SyncMetadata>{};

  @override
  Future<SyncMetadata?> read(String catalogIdentity) async =>
      _values[catalogIdentity];

  @override
  Future<void> write(SyncMetadata metadata) async =>
      _values[metadata.catalogIdentity] = metadata;

  @override
  Future<void> remove(String catalogIdentity) async =>
      _values.remove(catalogIdentity);
}

/// Application session state: selected database, theme preference, and services.
class AppController extends ChangeNotifier with WidgetsBindingObserver {
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
       } {
    DiagnosticDiagnostics.logger = diagnostics;
  }

  final DatabaseService database;
  final BackupService backups;
  final ExportService exporter = ExportService();
  final CatalogBundleService bundles = CatalogBundleService();
  late final ImportService importer = ImportService(database);
  late final ImageStorageService imageStorage = ImageStorageService(_http);
  late final DiagnosticLogger diagnostics = DiagnosticLogger();
  late final DiagnosticBundleService diagnosticBundles = DiagnosticBundleService(diagnostics);
  late final CatalogService catalog = CatalogService(
    database: database,
    images: imageStorage,
  );
  late final ExternalCatalogService lookup = ExternalCatalogService(
    _http,
    ownerName: openLibraryContactName,
    ownerEmail: openLibraryContactEmail,
  );
  final http.Client _http;
  final TokenStorage _tokenStorage;

  /// Test seam for avoiding platform path providers; persisted DB settings win.
  final String? imageRootPathOverride;
  final Map<String, SyncProvider> _providers;
  SyncProvider? _selectedProvider;
  SyncProvider? _pendingConnectionProvider;
  bool _pendingConnectionCancellationRequested = false;
  bool get isConnectionPending => _pendingConnectionProvider != null;
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
  bool _syncCoordinatorInitialized = false;
  SyncMetadata? syncMetadata;

  bool loading = true;
  String? error;
  String seedName = defaultThemeName;
  CatalogHierarchyOrder hierarchyOrder =
      CatalogHierarchyOrder.gameSystemSettingBookType;
  bool includePersonalImagesInBundles = false;
  bool diagnosticOptionsEnabled = false;
  bool debugLoggingEnabled = false;
  Future<void>? _syncFuture;
  Timer? _automaticSyncTimer;
  Future<void>? _automaticFuture;
  Future<void> _operationTail = Future<void>.value();
  bool automaticSyncEnabled = false;
  String deviceId = '';
  String deviceName = '';
  String openLibraryContactName = '';
  String openLibraryContactEmail = '';
  DateTime? automaticSyncLastAttempt;
  DateTime? automaticSyncLastSuccess;
  String? automaticSyncError;

  /// The coordinator owns the cloud lease. This flag is intentionally false
  /// until the coordinator has confirmed ownership; local preferences alone
  /// must never authorize an automatic upload.
  bool automaticSyncOwnershipValid = false;
  SyncProgress? syncProgress;
  bool get isSyncing => _syncFuture != null || syncCoordinator.isSyncing;
  void cancelSync() => syncCoordinator.cancel();

  Future<void> _cancelAndAwaitSync() async {
    _automaticSyncTimer?.cancel();
    final running = _syncFuture;
    if (running != null) {
      syncCoordinator.cancel();
      try {
        await running;
      } on Object {
        // Lifecycle changes intentionally absorb cancellation/failure; the
        // catalog remains intact and the next open can restore its metadata.
      }
    }
    final automatic = _automaticFuture;
    if (automatic != null) {
      try {
        await automatic;
      } on Object {
        // Closing is best effort and must not be blocked by cloud failure.
      }
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _operationTail.then((_) => action());
    _operationTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  // Work IDs observed after opening a database are the session baseline. Any
  // IDs appearing later are kept in memory only so the catalog can label them.
  final Set<int> _sessionBaselineWorkIds = <int>{};
  final Set<int> sessionNewWorkIds = <int>{};

  bool get isOpen => database.isOpen;
  String? get activeDatabasePath => isOpen ? database.databasePath : null;

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      diagnosticOptionsEnabled = prefs.getBool('diagnostic_options_enabled') ?? false;
      debugLoggingEnabled = prefs.getBool('diagnostic_debug_logging') ?? false;
      await diagnostics.configure(optionsEnabled: diagnosticOptionsEnabled, debugEnabled: debugLoggingEnabled);
      SyncDebug.diagnosticLogger = diagnostics;
      deviceId = prefs.getString('realmwise.device.id') ?? '';
      if (deviceId.isEmpty) {
        deviceId = _randomDeviceId();
        await prefs.setString('realmwise.device.id', deviceId);
      }
      deviceName = prefs.getString('realmwise.device.name') ?? '';
      if (deviceName.trim().isEmpty) {
        deviceName =
            defaultDeviceNameForHostname(_localHostname()) ??
            (Platform.isAndroid
                ? 'Android'
                : Platform.isWindows
                ? 'Windows'
                : 'Realmwise');
        await prefs.setString('realmwise.device.name', deviceName);
      }
      openLibraryContactName =
          prefs.getString('realmwise.openlibrary.contact.name') ?? '';
      openLibraryContactEmail =
          prefs.getString('realmwise.openlibrary.contact.email') ?? '';
      lookup.setOpenLibraryContact(
        name: openLibraryContactName,
        email: openLibraryContactEmail,
      );
      WidgetsBinding.instance.addObserver(this);
      _ensureSyncCoordinator(prefs);
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
      // Opening a database performs additional session setup, including the
      // image library.  Do not expose a partially opened catalog when one of
      // those later steps fails: screens may otherwise assume that image
      // storage is ready and throw while rendering.
      if (database.isOpen) await database.close();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> setDiagnosticOptionsEnabled(bool enabled) async {
    diagnosticOptionsEnabled = enabled;
    if (!enabled) debugLoggingEnabled = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('diagnostic_options_enabled', enabled);
    if (!enabled) await prefs.setBool('diagnostic_debug_logging', false);
    await diagnostics.configure(optionsEnabled: diagnosticOptionsEnabled, debugEnabled: debugLoggingEnabled);
    notifyListeners();
  }

  Future<void> setDebugLoggingEnabled(bool enabled) async {
    debugLoggingEnabled = diagnosticOptionsEnabled && enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('diagnostic_debug_logging', debugLoggingEnabled);
    await diagnostics.configure(optionsEnabled: diagnosticOptionsEnabled, debugEnabled: debugLoggingEnabled);
    notifyListeners();
  }

  Future<void> logDiagnostic(DiagnosticSeverity severity, String event, [Map<String, Object?> fields = const {}]) => diagnostics.log(severity, event, fields);

  String _localHostname() {
    try {
      return Platform.localHostname;
    } on Object {
      return '';
    }
  }

  String _randomDeviceId() {
    final random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
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
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on MissingPluginException {
      // Direct controller use in a headless/test environment has no platform
      // preferences; catalog opening remains usable with session-only sync
      // metadata in that case.
    }
    _ensureSyncCoordinator(prefs);
    await _cancelAndAwaitSync();
    syncCoordinator.resetRuntime();
    syncMetadata = null;
    _selectedProvider = null;
    error = null;
    await backups.stop();
    try {
      await database.open(databasePath);
      final catalogIdentity = await database.ensureCatalogIdentity();
      syncMetadata = await syncCoordinator.metadataStorage.read(
        catalogIdentity,
      );
      syncCoordinator.metadata = syncMetadata;
      automaticSyncEnabled = syncMetadata?.automaticSyncEnabled ?? false;
      automaticSyncOwnershipValid =
          automaticSyncEnabled &&
          syncMetadata?.deviceId == deviceId &&
          syncMetadata?.leaseToken != null &&
          (syncMetadata?.leaseExpiresAt?.isAfter(DateTime.now().toUtc()) ??
              false);
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
      final savedTheme = await database.getSetting('theme_seed');
      seedName = canonicalThemeName(savedTheme);
      if (savedTheme != seedName) {
        await database.setSetting('theme_seed', seedName);
      }
      final savedHierarchy = await database.getSetting(
        'catalog_hierarchy_order',
      );
      hierarchyOrder = savedHierarchy == 'gameSystemBookTypeSetting'
          ? CatalogHierarchyOrder.gameSystemBookTypeSetting
          : CatalogHierarchyOrder.gameSystemSettingBookType;
      await backups.start(
        databasePath: database.databasePath,
        database: database.databaseHandle,
      );
      if (remember) {
        if (prefs != null) {
          await prefs.setString('last_database_path', database.databasePath);
        }
      }
      notifyListeners();
      if (automaticSyncEnabled) scheduleAutomaticSync();
    } catch (exception) {
      // Opening the database is a transaction from the UI's perspective. If
      // image storage (or any later bootstrap step) fails, leave no live DB
      // behind for callers to mistake for a ready catalog.
      await backups.stop();
      await database.close();
      syncCoordinator.resetRuntime();
      syncMetadata = null;
      _selectedProvider = null;
      automaticSyncEnabled = false;
      automaticSyncOwnershipValid = false;
      _sessionBaselineWorkIds.clear();
      sessionNewWorkIds.clear();
      error = exception.toString();
      notifyListeners();
      rethrow;
    }
  }

  void _ensureSyncCoordinator(SharedPreferences? prefs) {
    if (_syncCoordinatorInitialized) return;
    syncCoordinator = SyncCoordinator(
      metadataStorage: prefs == null
          ? _InMemorySyncMetadataStorage()
          : SharedPreferencesSyncMetadataStorage(prefs),
    );
    _syncCoordinatorInitialized = true;
  }

  Future<void> setDeviceName(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) throw ArgumentError('Enter a device name.');
    deviceName = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('realmwise.device.name', trimmed);
    notifyListeners();
  }

  Future<void> setOpenLibraryContact({
    required String name,
    required String email,
  }) async {
    final trimmedName = name.trim();
    final trimmedEmail = email.trim();
    openLibraryContactName = trimmedName;
    openLibraryContactEmail = trimmedEmail;
    final prefs = await SharedPreferences.getInstance();
    if (trimmedName.isEmpty) {
      await prefs.remove('realmwise.openlibrary.contact.name');
    } else {
      await prefs.setString(
        'realmwise.openlibrary.contact.name',
        trimmedName,
      );
    }
    if (trimmedEmail.isEmpty) {
      await prefs.remove('realmwise.openlibrary.contact.email');
    } else {
      await prefs.setString(
        'realmwise.openlibrary.contact.email',
        trimmedEmail,
      );
    }
    lookup.setOpenLibraryContact(name: trimmedName, email: trimmedEmail);
    notifyListeners();
  }

  Future<void> setAutomaticSyncEnabled(bool enabled) async {
    final metadata = syncCoordinator.metadata;
    if (metadata == null || !syncCoordinator.isConnected) {
      throw StateError(
        'Connect a cloud provider before enabling automatic sync.',
      );
    }
    _automaticSyncTimer?.cancel();
    if (enabled) {
      await syncCoordinator.enableAutomaticSync(
        deviceId: deviceId,
        deviceName: deviceName,
      );
      automaticSyncOwnershipValid = true;
      scheduleAutomaticSync();
    } else {
      await syncCoordinator.disableAutomaticSync();
      automaticSyncOwnershipValid = false;
    }
    automaticSyncEnabled = enabled;
    automaticSyncError = null;
    syncMetadata = syncCoordinator.metadata;
    notifyListeners();
  }

  Future<void> takeOverAutomaticSync() async {
    if (!syncCoordinator.isConnected) {
      throw StateError('Connect a cloud provider first.');
    }
    await syncCoordinator.takeOverAutomaticSync(
      deviceId: deviceId,
      deviceName: deviceName,
      confirmed: true,
    );
    automaticSyncEnabled = true;
    automaticSyncOwnershipValid = false;
    syncMetadata = syncCoordinator.metadata;
    notifyListeners();
    // A takeover must validate the remote state before the first upload.
    await _validateAutomaticRemote();
  }

  void scheduleAutomaticSync({Duration debounce = const Duration(seconds: 5)}) {
    if (!automaticSyncEnabled || !automaticSyncOwnershipValid) return;
    _automaticSyncTimer?.cancel();
    _automaticSyncTimer = Timer(debounce, () {
      final running = _runAutomaticSync();
      _automaticFuture = running;
      unawaited(
        running.whenComplete(() {
          if (identical(_automaticFuture, running)) _automaticFuture = null;
        }),
      );
    });
  }

  Future<void> _runAutomaticSync() async {
    if (!automaticSyncEnabled || !automaticSyncOwnershipValid || isSyncing)
      return;
    automaticSyncLastAttempt = DateTime.now().toUtc();
    notifyListeners();
    try {
      await _serialize(_automaticUploadInternal);
      automaticSyncLastSuccess = DateTime.now().toUtc();
      automaticSyncError = null;
    } catch (error) {
      automaticSyncError = error.toString().replaceFirst('Exception: ', '');
      if (error is SyncLeaseLostException) {
        automaticSyncEnabled = false;
        automaticSyncOwnershipValid = false;
        _automaticSyncTimer?.cancel();
        syncMetadata = syncCoordinator.metadata;
      }
    }
    notifyListeners();
  }

  Future<void> _automaticUploadInternal() async {
    if (!database.isOpen) throw StateError('Open a catalog first.');
    final temporary = await getTemporaryDirectory();
    final bundlePath = path.join(
      temporary.path,
      'realmwise-auto-${DateTime.now().microsecondsSinceEpoch}.realmwise',
    );
    try {
      await exportDeviceBundle(bundlePath);
      final manifest = await bundles.validateBundle(bundlePath);
      syncMetadata = await syncCoordinator.automaticUpload(
        Uint8List.fromList(await File(bundlePath).readAsBytes()),
        localFingerprint: manifest.contentFingerprint,
      );
    } finally {
      final file = File(bundlePath);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _validateAutomaticRemote() async {
    final temporary = await getTemporaryDirectory();
    final bundlePath = path.join(
      temporary.path,
      'realmwise-auto-validate-${DateTime.now().microsecondsSinceEpoch}.realmwise',
    );
    try {
      await _serialize(() async {
        await exportDeviceBundle(bundlePath);
        final manifest = await bundles.validateBundle(bundlePath);
        final decision = await syncCoordinator.classify(
          manifest.contentFingerprint,
        );
        if (decision.classification == SyncClassification.divergent ||
            decision.classification == SyncClassification.unknownError ||
            decision.classification == SyncClassification.remoteOnly) {
          throw SyncDecisionRequired(
            decision,
            localFingerprint: manifest.contentFingerprint,
          );
        }
      });
      automaticSyncOwnershipValid = true;
      syncMetadata = syncCoordinator.metadata;
      scheduleAutomaticSync();
      notifyListeners();
    } catch (_) {
      automaticSyncOwnershipValid = false;
      rethrow;
    } finally {
      final file = File(bundlePath);
      if (await file.exists()) await file.delete();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (automaticSyncEnabled) unawaited(_refreshAutomaticLease());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Best effort only: lifecycle callbacks must never delay closing.
      if (automaticSyncEnabled && automaticSyncOwnershipValid) {
        final running = _runAutomaticSync();
        _automaticFuture = running;
        unawaited(
          running.whenComplete(() {
            if (identical(_automaticFuture, running)) _automaticFuture = null;
          }),
        );
      }
    }
  }

  Future<void> _refreshAutomaticLease() async {
    try {
      final lease = await syncCoordinator.refreshAutomaticLease();
      automaticSyncOwnershipValid = lease != null;
      syncMetadata = syncCoordinator.metadata;
      if (lease != null) scheduleAutomaticSync();
      notifyListeners();
    } catch (error) {
      automaticSyncError = error.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
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
    await _cancelAndAwaitSync();
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
    _pendingConnectionProvider = provider;
    _pendingConnectionCancellationRequested = false;
    notifyListeners();
    try {
      syncMetadata = await syncCoordinator.connect(provider, identity);
      if (_pendingConnectionCancellationRequested &&
          identical(_pendingConnectionProvider, provider)) {
        throw const SyncCancelledException();
      }
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
        if (_pendingConnectionCancellationRequested &&
            identical(_pendingConnectionProvider, provider)) {
          throw const SyncCancelledException();
        }
      }
      // Keep the persisted sync policy aligned with the bundle export policy.
      await setIncludePersonalImagesInBundles(includePersonalImagesInBundles);
      if (_pendingConnectionCancellationRequested &&
          identical(_pendingConnectionProvider, provider)) {
        throw const SyncCancelledException();
      }
    } catch (error) {
      if (_pendingConnectionCancellationRequested &&
          identical(_pendingConnectionProvider, provider)) {
        syncCoordinator.resetRuntime();
        syncMetadata = null;
      } else {
        await syncCoordinator.failConnection(error);
        syncMetadata = syncCoordinator.metadata;
      }
      notifyListeners();
      rethrow;
    } finally {
      if (identical(_pendingConnectionProvider, provider)) {
        _pendingConnectionProvider = null;
        _pendingConnectionCancellationRequested = false;
        notifyListeners();
      }
    }
    _selectedProvider = provider;
    notifyListeners();
  }

  Future<void> cancelPendingConnection() async {
    final provider = _pendingConnectionProvider;
    if (provider == null) return;
    _pendingConnectionCancellationRequested = true;
    notifyListeners();
    try {
      if (provider is DropboxProvider) {
        await provider.cancelPendingAuthentication();
      } else if (provider is OneDriveProvider) {
        await provider.cancelPendingAuthentication();
      } else if (provider is GoogleDriveProvider) {
        await provider.cancelPendingAuthentication();
      }
    } finally {
      notifyListeners();
    }
  }

  Future<void> connectGoogleDrive() => _connect(_providers['google_drive']);
  Future<void> connectOneDrive() => _connect(_providers['onedrive']);
  Future<void> connectDropbox() => _connect(_providers['dropbox']);

  Future<void> disconnectOneDrive() => disconnectGoogleDrive();

  Future<void> syncNow() {
    final running = _syncFuture;
    if (running != null) return Future<void>.error(const SyncBusyException());
    final operation = _syncNowInternal();
    _syncFuture = operation;
    return operation.whenComplete(() {
      if (identical(_syncFuture, operation)) _syncFuture = null;
      syncProgress = null;
    });
  }

  Future<void> _syncNowInternal() async {
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
        onProgress: (value) {
          syncProgress = value;
          notifyListeners();
        },
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
  Future<bool> resolveSyncDecision(
    SyncConflictChoice choice, {
    required SyncClassificationResult decision,
    required String localFingerprint,
  }) async {
    if (choice == SyncConflictChoice.cancel) return false;
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
        return downloadRemoteBundle(
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
        return false;
      }
    } finally {
      final file = File(bundlePath);
      if (await file.exists()) await file.delete();
    }
  }

  Future<bool> downloadRemoteBundle({
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
          throw SyncDecisionRequired(
            decision,
            localFingerprint: local.contentFingerprint,
          );
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
    final runtimeSnapshot = syncCoordinator.captureRuntime();
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
      if (runtimeSnapshot != null) {
        SyncMetadata? rebound;
        final registered = _providers[runtimeSnapshot.provider.provider];
        if (!identical(registered, runtimeSnapshot.provider)) {
          SyncDebug.trace('restore.rebind.error', const {
            'status': 'provider_mismatch',
          });
          syncCoordinator.resetRuntime();
          syncMetadata = null;
          _selectedProvider = null;
        } else {
          try {
            rebound = await syncCoordinator.rebindAfterCatalogRestore(
              runtimeSnapshot,
              catalogIdentity: manifest.catalogIdentity,
              remote: result.metadata,
              localFingerprint: manifest.contentFingerprint,
            );
          } catch (_) {
            // Rebinding is best effort, but never fall back to credentials or
            // metadata restored from the replacement catalog.
            SyncDebug.trace('restore.rebind.error', const {'status': 'failed'});
            syncCoordinator.resetRuntime();
            syncMetadata = null;
            _selectedProvider = null;
            automaticSyncEnabled = false;
            automaticSyncOwnershipValid = false;
            rethrow;
          }
          if (rebound == null) {
            SyncDebug.trace('restore.rebind.error', const {
              'status': 'rejected',
            });
            syncCoordinator.resetRuntime();
            syncMetadata = null;
            _selectedProvider = null;
          } else {
            _selectedProvider = registered;
            syncMetadata = rebound;
          }
        }
      } else {
        // A plain/manual import must not inherit the just-downloaded remote
        // revision. Keep only any normal persisted restoration performed by
        // openDatabase for this catalog identity.
        syncMetadata = syncCoordinator.metadata;
      }
      automaticSyncEnabled = syncMetadata?.automaticSyncEnabled ?? false;
      automaticSyncOwnershipValid =
          automaticSyncEnabled &&
          syncMetadata?.deviceId == deviceId &&
          syncMetadata?.leaseToken != null &&
          (syncMetadata?.leaseExpiresAt?.isAfter(DateTime.now().toUtc()) ??
              false);
      if (!automaticSyncOwnershipValid) {
        _automaticSyncTimer?.cancel();
      } else {
        scheduleAutomaticSync();
      }
      notifyListeners();
      return true;
    } finally {
      final file = File(bundlePath);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> disconnectGoogleDrive() async {
    await _cancelAndAwaitSync();
    final provider = _selectedProvider;
    final active = syncCoordinator.metadata;
    final session = syncCoordinator.session;
    if (provider is GoogleDriveProvider) await provider.clearCredentials();
    if (provider is OneDriveProvider) await provider.clearCredentials();
    if (provider is DropboxProvider) await provider.clearCredentials();
    // Provider implementations may have their own cleanup, but deleting the
    // canonical key here also protects custom/test providers from leaving a
    // credential behind after disconnect.
    if (active?.provider != null && session != null) {
      await _tokenStorage.delete(
        syncCredentialKey(
          catalogIdentity: active!.catalogIdentity,
          provider: active.provider!,
          accountId: session.accountId,
        ),
      );
    }
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
    final current = syncCoordinator.metadata;
    if (current != null) {
      syncCoordinator.metadata = SyncMetadata(
        catalogIdentity: current.catalogIdentity,
        provider: current.provider,
        accountId: current.accountId,
        accountDisplayName: current.accountDisplayName,
        remoteTargetId: current.remoteTargetId,
        remoteTargetName: current.remoteTargetName,
        revision: current.revision,
        contentHash: current.contentHash,
        lastSuccessfulLocalFingerprint: current.lastSuccessfulLocalFingerprint,
        createdAt: current.createdAt,
        updatedAt: current.updatedAt,
        state: current.state,
        error: current.error,
        includePersonalImages: value,
        retainedRevisionCount: current.retainedRevisionCount,
      );
      syncMetadata = syncCoordinator.metadata;
      await syncCoordinator.metadataStorage.write(syncMetadata!);
    }
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
    seedName = canonicalThemeName(name);
    await database.setSetting('theme_seed', seedName);
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
    scheduleAutomaticSync();
  }

  /// Clears the session-only NEW marker for a work once it is selected.
  void clearSessionNewWork(int? workId) {
    if (workId != null && sessionNewWorkIds.remove(workId)) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _automaticSyncTimer?.cancel();
    unawaited(backups.stop());
    unawaited(database.close());
    _http.close();
    super.dispose();
  }
}
