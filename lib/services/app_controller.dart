import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
//import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database_service.dart';
import '../models/catalog_models.dart';
import '../sync/sync_session.dart';
import 'catalog_recovery.dart';
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

class _SyncActivity {
  bool active = true;
}

/// Application session state: selected database, theme preference, and services.
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({
    TokenStorage? tokenStorage,
    DateTime Function()? clock,
    Timer Function(Duration, void Function(Timer))? periodicTimer,
    this.imageRootPathOverride,
    SyncProvider? syncProvider,
    SyncProvider? googleDriveProvider,
    SyncProvider? oneDriveProvider,
    SyncProvider? dropboxProvider,
  }) : clock = clock ?? DateTime.now,
       periodicTimer = periodicTimer ?? Timer.periodic,
       database = DatabaseService(),
       _http = http.Client(),
       _tokenStorage = tokenStorage ?? SecureStorageService(),
       _providers = {
         'google_drive': ?googleDriveProvider,
         'onedrive': ?oneDriveProvider,
         'dropbox': ?dropboxProvider,
         ..._providerEntry(syncProvider),
       } {
    DiagnosticDiagnostics.logger = diagnostics;
  }

  final DateTime Function() clock;
  final Timer Function(Duration, void Function(Timer)) periodicTimer;
  final DatabaseService database;

  static Map<String, SyncProvider> _providerEntry(SyncProvider? provider) =>
      switch (provider) {
        null => const {},
        final provider => {provider.provider: provider},
      };

  late final CatalogRecovery recovery = CatalogRecovery(
    database: database,
    waitForSync: () => _cancelAndAwaitSync(cancelManual: false),
    beforeClose: () => catalog.discardEdits(),
    reopen: _openDatabase,
    clock: clock,
    rehydrate: () => catalog.rehydrateMissingImages(),
    onReady: _resumeAfterRecovery,
  );
  final ExportService exporter = ExportService();
  final CatalogBundleService bundles = CatalogBundleService();
  late final ImportService importer = ImportService(database);
  late final ImageStorageService imageStorage = ImageStorageService(_http);
  late final DiagnosticLogger diagnostics = DiagnosticLogger();
  late final DiagnosticBundleService diagnosticBundles =
      DiagnosticBundleService(diagnostics);
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
  ThemeMode themeMode = ThemeMode.system;
  CatalogHierarchyOrder hierarchyOrder =
      CatalogHierarchyOrder.gameSystemSettingBookType;
  bool includePersonalImagesInBundles = false;
  bool diagnosticOptionsEnabled = false;
  bool debugLoggingEnabled = false;
  Timer? _automaticSyncTimer;
  Timer? _leaseRenewalTimer;
  Future<void>? _leaseRenewalFuture;
  bool _foreground = true;
  bool _backgrounded = false;
  bool _disposed = false;
  Future<void>? _automaticFuture;
  bool _automaticSyncPending = false;
  bool _automaticBackgroundFlushPending = false;
  SyncCancellationToken? _automaticCancellation;
  SyncCancellationToken? _automaticTransferCancellation;
  Future<void> _operationTail = Future<void>.value();
  Timer? _syncCompletionTimer;
  // Nested work may replace its own catalog. Only a live activity token
  // permits that replacement to omit waiting on its own caller.
  final _syncActivityZone = Object();
  final Set<Future<void>> _syncActivities = {};

  bool get _insideSyncActivity {
    final activity = Zone.current[_syncActivityZone];
    return activity is _SyncActivity && activity.active;
  }

  Future<T> _trackSyncActivity<T>(Future<T> Function() action) {
    if (isSyncing || recovery.isReplacing || isConnectionPending) {
      return Future.error(const SyncBusyException());
    }
    final activity = _SyncActivity();
    final operation = runZoned(
      action,
      zoneValues: {_syncActivityZone: activity},
    ).whenComplete(() => activity.active = false);
    final settled = operation.then<void>((_) {}, onError: (Object _) {});
    _syncActivities.add(settled);
    unawaited(
      settled.whenComplete(() {
        _syncActivities.remove(settled);
        _queuePendingAutomaticSync();
      }),
    );
    return operation;
  }

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
  bool get isSyncing =>
      _syncActivities.isNotEmpty ||
      (_syncCoordinatorInitialized && syncCoordinator.isSyncing);

  void cancelSync() {
    syncSession.cancel();
    if (_syncCoordinatorInitialized) syncCoordinator.cancel();
  }

  Future<void> _cancelAndAwaitSync({bool cancelManual = true}) async {
    _clearPendingAutomaticSync();
    _cancelAutomaticTimers();
    _automaticCancellation?.cancel();
    // A download replaces its own catalog while it holds the operation queue.
    // Awaiting that download or anything queued behind it would deadlock.
    if (_insideSyncActivity) return;
    if (cancelManual) {
      syncSession.invalidateDecision();
      cancelSync();
    } else if (_syncCoordinatorInitialized) {
      syncCoordinator.cancel();
    }
    await Future.wait(_syncActivities.toList());
    await _leaseRenewalFuture;
    final automatic = _automaticFuture;
    if (automatic != null) {
      try {
        await automatic;
      } on Object {
        // Closing is best effort and must not be blocked by cloud failure.
      }
    }
  }

  void _clearPendingAutomaticSync() {
    _automaticSyncPending = false;
    _automaticBackgroundFlushPending = false;
  }

  void _cancelAutomaticTimers() {
    _syncCompletionTimer?.cancel();
    _syncCompletionTimer = null;
    _leaseRenewalTimer?.cancel();
    _leaseRenewalTimer = null;
    _automaticSyncTimer?.cancel();
    _automaticSyncTimer = null;
  }

  bool get _hasAutomaticOwnership =>
      automaticSyncEnabled &&
      syncMetadata?.deviceId == deviceId &&
      syncMetadata?.leaseToken != null &&
      (syncMetadata?.leaseExpiresAt?.isAfter(clock().toUtc()) ?? false);

  String _syncErrorMessage(Object error) => SyncFailed.fromError(error).message;

  void _clearAutomaticSyncState() {
    _clearPendingAutomaticSync();
    _cancelAutomaticTimers();
    automaticSyncEnabled = false;
    automaticSyncOwnershipValid = false;
    automaticSyncError = null;
    automaticSyncLastAttempt = null;
    automaticSyncLastSuccess = null;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _operationTail.then((_) => action());
    _operationTail = result.then<void>((_) {}, onError: (_, _) {});
    unawaited(_operationTail.then((_) => _queuePendingAutomaticSync()));
    return result;
  }

  void _queuePendingAutomaticSync() {
    if (!_automaticSyncPending ||
        _disposed ||
        _syncActivities.isNotEmpty ||
        (_automaticSyncTimer?.isActive ?? false))
      return;
    _syncCompletionTimer?.cancel();
    // Let callers finish clearing their busy/cancellation state first.
    _syncCompletionTimer = Timer(Duration.zero, () {
      _syncCompletionTimer = null;
      _resumePendingAutomaticSync();
    });
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
      diagnosticOptionsEnabled =
          prefs.getBool('diagnostic_options_enabled') ?? false;
      debugLoggingEnabled = prefs.getBool('diagnostic_debug_logging') ?? false;
      await diagnostics.configure(
        optionsEnabled: diagnosticOptionsEnabled,
        debugEnabled: debugLoggingEnabled,
      );
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
      if (saved != null) await recovery.recoverInterruptedReplacement(saved);
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
    await diagnostics.configure(
      optionsEnabled: diagnosticOptionsEnabled,
      debugEnabled: debugLoggingEnabled,
    );
    notifyListeners();
  }

  Future<void> setDebugLoggingEnabled(bool enabled) async {
    debugLoggingEnabled = diagnosticOptionsEnabled && enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('diagnostic_debug_logging', debugLoggingEnabled);
    await diagnostics.configure(
      optionsEnabled: diagnosticOptionsEnabled,
      debugEnabled: debugLoggingEnabled,
    );
    notifyListeners();
  }

  Future<void> logDiagnostic(
    DiagnosticSeverity severity,
    String event, [
    Map<String, Object?> fields = const {},
  ]) => diagnostics.log(severity, event, fields);

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
    if (_syncCoordinatorInitialized) await _cancelAndAwaitSync();
    await catalog.discardEdits();
    await _openDatabase(databasePath, remember: remember);
    try {
      await recovery.start();
      await _resumeAfterRecovery();
    } on Object {
      await closeDatabase();
      rethrow;
    }
  }

  Future<void> _openDatabase(
    String databasePath, {
    bool remember = true,
  }) async {
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
    syncCoordinator.resetRuntime();
    syncMetadata = null;
    _selectedProvider = null;
    error = null;
    await recovery.stop();
    try {
      await database.open(databasePath);
      await recovery.loadWarning();
      final catalogIdentity = await database.ensureCatalogIdentity();
      syncMetadata = await syncCoordinator.metadataStorage.read(
        catalogIdentity,
      );
      syncCoordinator.metadata = syncMetadata;
      automaticSyncEnabled = syncMetadata?.automaticSyncEnabled ?? false;
      automaticSyncOwnershipValid = _hasAutomaticOwnership;
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
      await catalog.cleanupAbandonedEdits();
      final savedTheme = await database.getSetting('theme_seed');
      seedName = canonicalThemeName(savedTheme);
      if (savedTheme != seedName) {
        await database.setSetting('theme_seed', seedName);
      }
      final savedThemeMode = await database.getSetting('theme_mode');
      themeMode = switch (savedThemeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      if (savedThemeMode != themeMode.name) {
        await database.setSetting('theme_mode', themeMode.name);
      }
      final savedHierarchy = await database.getSetting(
        'catalog_hierarchy_order',
      );
      hierarchyOrder = savedHierarchy == 'gameSystemBookTypeSetting'
          ? CatalogHierarchyOrder.gameSystemBookTypeSetting
          : CatalogHierarchyOrder.gameSystemSettingBookType;
      if (remember) {
        if (prefs != null) {
          await prefs.setString('last_database_path', database.databasePath);
        }
      }
    } catch (exception) {
      // Opening the database is a transaction from the UI's perspective. If
      // image storage (or any later bootstrap step) fails, leave no live DB
      // behind for callers to mistake for a ready catalog.
      await recovery.stop();
      await database.close();
      syncCoordinator.resetRuntime();
      syncMetadata = null;
      _selectedProvider = null;
      _clearAutomaticSyncState();
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
      clock: clock,
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
      await prefs.setString('realmwise.openlibrary.contact.name', trimmedName);
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

  Future<void> setAutomaticSyncEnabled(bool enabled) {
    if (!enabled) {
      _clearPendingAutomaticSync();
      _cancelAutomaticTimers();
      _automaticCancellation?.cancel();
      _automaticTransferCancellation?.cancel();
    }
    return _serialize(() => _setAutomaticSyncEnabled(enabled));
  }

  Future<void> _setAutomaticSyncEnabled(bool enabled) async {
    final metadata = syncCoordinator.metadata;
    if (metadata == null || !syncCoordinator.isConnected) {
      throw StateError(
        'Connect a cloud provider before enabling automatic sync.',
      );
    }
    _cancelAutomaticTimers();
    if (enabled) {
      await syncCoordinator.enableAutomaticSync(
        deviceId: deviceId,
        deviceName: deviceName,
      );
      automaticSyncOwnershipValid = true;
    } else {
      await syncCoordinator.disableAutomaticSync();
      automaticSyncOwnershipValid = false;
    }
    automaticSyncEnabled = enabled;
    if (enabled) {
      _startLeaseRenewal();
      scheduleAutomaticSync();
    }
    automaticSyncError = null;
    syncMetadata = syncCoordinator.metadata;
    notifyListeners();
  }

  Future<void> takeOverAutomaticSync() =>
      _trackSyncActivity(() => _serialize(_takeOverAutomaticSyncInternal));

  Future<void> _takeOverAutomaticSyncInternal() async {
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
    _startLeaseRenewal();
  }

  void scheduleAutomaticSync({Duration debounce = const Duration(seconds: 5)}) {
    if (recovery.warning != null ||
        _disposed ||
        !automaticSyncEnabled ||
        !automaticSyncOwnershipValid)
      return;
    _automaticSyncPending = true;
    if (!_foreground) return;
    _automaticSyncTimer?.cancel();
    _automaticSyncTimer = Timer(debounce, () {
      _automaticSyncTimer = null;
      _launchAutomaticSync();
    });
  }

  void _launchAutomaticSync() {
    if (!_automaticSyncPending || _automaticCancellation != null) return;
    final running = _runAutomaticSync();
    _automaticFuture = running;
    unawaited(
      running.whenComplete(() {
        if (identical(_automaticFuture, running)) _automaticFuture = null;
      }),
    );
  }

  void _resumePendingAutomaticSync() {
    if (!_automaticSyncPending ||
        recovery.warning != null ||
        recovery.isReplacing ||
        _disposed ||
        !automaticSyncEnabled ||
        !automaticSyncOwnershipValid ||
        _automaticCancellation != null ||
        isSyncing ||
        isConnectionPending)
      return;
    if (_foreground) {
      scheduleAutomaticSync();
    } else if (_automaticBackgroundFlushPending) {
      scheduleMicrotask(_launchAutomaticSync);
    }
  }

  Future<void> _runAutomaticSync() async {
    if (recovery.warning != null ||
        recovery.isReplacing ||
        _disposed ||
        !automaticSyncEnabled ||
        !automaticSyncOwnershipValid ||
        isSyncing ||
        isConnectionPending)
      return;
    _automaticSyncPending = false;
    _automaticBackgroundFlushPending = false;
    final cancellation = SyncCancellationToken();
    _automaticCancellation = cancellation;
    automaticSyncLastAttempt = clock().toUtc();
    notifyListeners();
    try {
      await _serialize(() => _automaticUploadInternal(cancellation));
      automaticSyncLastSuccess = clock().toUtc();
      automaticSyncError = null;
    } on SyncCancelledException {
      // Disabling automatic sync intentionally cancels queued/pre-transfer work.
    } on SyncBusyException {
      _automaticSyncPending = true;
    } catch (error) {
      automaticSyncError = _syncErrorMessage(error);
      if (error is SyncLeaseLostException) {
        _cancelAutomaticTimers();
        automaticSyncEnabled = false;
        automaticSyncOwnershipValid = false;
        _automaticSyncTimer?.cancel();
        syncMetadata = syncCoordinator.metadata;
      }
    } finally {
      _automaticCancellation = null;
      _automaticTransferCancellation = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _automaticUploadInternal(
    SyncCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (recovery.warning != null) return;
    void ensureIdle() {
      if (isSyncing || isConnectionPending) throw const SyncBusyException();
    }

    ensureIdle();
    if (!database.isOpen) throw StateError('Open a catalog first.');
    await syncSession.automaticUpload(
      cancellation,
      beforeTransfer: ensureIdle,
      onTransfer: (token) => _automaticTransferCancellation = token,
    );
    syncMetadata = syncCoordinator.metadata;
  }

  Future<void> _validateAutomaticRemote() async {
    try {
      final status = await syncSession.validateAutomaticRemote();
      final classification = status.classification;
      if (classification != SyncClassification.localOnly &&
          classification != SyncClassification.noChanges) {
        throw SyncConflictException(
          status.remote ??
              const SyncRemoteMetadata(
                revision: SyncRevision(''),
                contentHash: '',
              ),
        );
      }
      automaticSyncOwnershipValid = true;
      syncMetadata = syncCoordinator.metadata;
      scheduleAutomaticSync();
      notifyListeners();
    } catch (_) {
      automaticSyncOwnershipValid = false;
      rethrow;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    final hadPendingUpload =
        _automaticSyncPending || (_automaticSyncTimer?.isActive ?? false);
    // Desktop focus loss is inactive while the window remains visible.
    _foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (!_foreground) {
      _backgrounded = true;
      _cancelAutomaticTimers();
    }
    if (state == AppLifecycleState.resumed && _backgrounded) {
      _backgrounded = false;
      if (automaticSyncEnabled) {
        unawaited(_refreshAutomaticLease());
        _startLeaseRenewal();
      }
    } else if (wasForeground &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      // Best effort only: lifecycle callbacks must never delay closing.
      if (hadPendingUpload &&
          automaticSyncEnabled &&
          automaticSyncOwnershipValid) {
        _automaticSyncPending = true;
        _automaticBackgroundFlushPending = true;
        _launchAutomaticSync();
      }
    }
  }

  void _startLeaseRenewal() {
    _leaseRenewalTimer?.cancel();
    if (!_foreground ||
        _disposed ||
        !automaticSyncEnabled ||
        !syncCoordinator.isConnected)
      return;
    _leaseRenewalTimer = periodicTimer(const Duration(minutes: 5), (_) {
      if (!isSyncing) unawaited(_refreshAutomaticLease());
    });
  }

  Future<void> _refreshAutomaticLease() {
    if (_disposed || !_foreground || !automaticSyncEnabled)
      return Future.value();
    return _leaseRenewalFuture ??= _serialize(() async {
      if (_disposed || !_foreground || !automaticSyncEnabled) return;
      try {
        final lease = await syncCoordinator.refreshAutomaticLease();
        automaticSyncOwnershipValid = lease != null;
        syncMetadata = syncCoordinator.metadata;
        automaticSyncEnabled = syncMetadata?.automaticSyncEnabled ?? false;
        if (lease != null) {
          scheduleAutomaticSync();
        } else {
          _cancelAutomaticTimers();
        }
      } catch (error) {
        automaticSyncError = _syncErrorMessage(error);
      }
      if (!_disposed) notifyListeners();
    }).whenComplete(() => _leaseRenewalFuture = null);
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
    await recovery.scrubLegacyTokens();
  }

  Future<void> closeDatabase() async {
    await _cancelAndAwaitSync();
    await catalog.discardEdits();
    await recovery.stop();
    await database.close();
    syncCoordinator.resetRuntime();
    syncMetadata = null;
    _selectedProvider = null;
    _clearAutomaticSyncState();
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
    if (isSyncing || _automaticCancellation != null || isConnectionPending) {
      throw const SyncBusyException();
    }
    _pendingConnectionProvider = provider;
    _pendingConnectionCancellationRequested = false;
    notifyListeners();
    try {
      final identity = await database.ensureCatalogIdentity();
      syncMetadata = await syncCoordinator.connect(provider, identity);
      automaticSyncEnabled = syncMetadata?.automaticSyncEnabled ?? false;
      automaticSyncOwnershipValid = _hasAutomaticOwnership;
      automaticSyncError = null;
      automaticSyncLastAttempt = null;
      automaticSyncLastSuccess = null;
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
      _clearAutomaticSyncState();
      notifyListeners();
      rethrow;
    } finally {
      if (identical(_pendingConnectionProvider, provider)) {
        _pendingConnectionProvider = null;
        _pendingConnectionCancellationRequested = false;
        _resumePendingAutomaticSync();
        notifyListeners();
      }
    }
    _selectedProvider = provider;
    if (automaticSyncEnabled) {
      await _refreshAutomaticLease();
      _startLeaseRenewal();
    }
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

  Future<void> connectSelectedProvider() => _connect(_selectedProvider);

  Future<void> connectGoogleDrive() => _connect(_providers['google_drive']);
  Future<void> connectOneDrive() => _connect(_providers['onedrive']);
  Future<void> connectDropbox() => _connect(_providers['dropbox']);

  Future<void> disconnectOneDrive() => disconnectGoogleDrive();

  late final SyncSession syncSession = SyncSession(
    coordinator: () => syncCoordinator,
    recovery: () => recovery,
    exportBundle: exportDeviceBundle,
    localFingerprint: () => bundles.localFingerprint(
      database: database,
      includePersonalImages: includePersonalImagesInBundles,
    ),
    catalogGeneration: () => database.catalogGeneration,
    registeredProvider: (id) => _providers[id],
    imageRootPath: () => imageStorage.rootPath,
    bundles: bundles,
    runOperation: _runManualSync,
    onProgress: (progress) {
      syncProgress = progress;
      notifyListeners();
    },
    onReplacement: _onCloudCatalogReplacement,
  );

  Future<SyncResult> syncCatalog() => syncSession.sync();

  Future<SyncResult> downloadCatalog() => syncSession.download();

  Future<SyncResult> answerSyncDecision(
    SyncDecision request,
    SyncChoice choice,
  ) => syncSession.answer(request, choice);

  Future<SyncResult> _runManualSync(Future<SyncResult> Function() action) =>
      _trackSyncActivity(
        () => _serialize(() async {
          try {
            if (!database.isOpen) {
              return const SyncFailed(
                SyncFailureCategory.storage,
                'Open a catalog first.',
              );
            }
            return await action();
          } finally {
            if (_syncCoordinatorInitialized)
              syncMetadata = syncCoordinator.metadata;
            syncProgress = null;
            if (!_disposed) notifyListeners();
          }
        }),
      );

  void _onCloudCatalogReplacement() {
    syncMetadata = syncCoordinator.metadata;
    _selectedProvider = syncCoordinator.provider;
    automaticSyncEnabled = syncMetadata?.automaticSyncEnabled ?? false;
    automaticSyncOwnershipValid =
        recovery.warning == null && _hasAutomaticOwnership;
    if (automaticSyncOwnershipValid) {
      scheduleAutomaticSync();
    } else {
      _automaticSyncTimer?.cancel();
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
    _clearAutomaticSyncState();
    notifyListeners();
  }

  Future<CatalogReplacementResult> restoreFromBackup(RestorePoint point) async {
    final result = await recovery.restore(
      point,
      imageRootPath: imageStorage.rootPath,
    );
    notifyListeners();
    return result;
  }

  CatalogRecoveryWarning? get recoveryWarning =>
      isOpen ? recovery.warning : null;

  Future<void> acknowledgeRecoveryWarning() async {
    await recovery.acknowledgeWarning();
    await _resumeAfterRecovery();
  }

  Future<void> _resumeAfterRecovery() async {
    if (recovery.warning != null) {
      notifyListeners();
      return;
    }
    // A downloaded catalog rebinds its connection after the local swap returns.
    if (_syncActivities.isNotEmpty) return;
    if (automaticSyncEnabled && syncCoordinator.isConnected) {
      await _refreshAutomaticLease();
      _startLeaseRenewal();
    } else if (automaticSyncEnabled && automaticSyncOwnershipValid)
      scheduleAutomaticSync();
    notifyListeners();
  }

  Future<void> createManualSnapshot() async {
    await recovery.snapshot(SnapshotKind.manual);
  }

  Future<void> exportDeviceBundle(String outputPath) => bundles.exportBundle(
    database: database,
    outputPath: outputPath,
    imageRootPath: imageStorage.rootPath,
    includePersonalImages: includePersonalImagesInBundles,
  );

  Future<void> setIncludePersonalImagesInBundles(bool value) =>
      _serialize(() => _setIncludePersonalImagesInBundles(value));

  Future<void> _setIncludePersonalImagesInBundles(bool value) async {
    includePersonalImagesInBundles = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('include_personal_images_in_bundles', value);
    final current = syncCoordinator.metadata;
    if (current != null) {
      syncCoordinator.metadata = current.copyWith(
        includePersonalImages: value,
        updatedAt: clock().toUtc(),
      );
      syncMetadata = syncCoordinator.metadata;
      await syncCoordinator.metadataStorage.write(syncMetadata!);
    }
    notifyListeners();
  }

  Future<CatalogReplacementResult> restoreDeviceBundle(
    String bundlePath, {
    SnapshotKind snapshotKind = SnapshotKind.preImport,
  }) async {
    final result = await recovery.replaceCatalog(
      bundlePath,
      bundle: true,
      snapshotKind: snapshotKind,
      imageRootPath: imageStorage.rootPath,
    );
    notifyListeners();
    return result;
  }

  /// Validates an import without mutating the active catalog.
  Future<BundleManifest> previewDeviceBundle(String bundlePath) =>
      bundles.validateBundle(bundlePath);

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

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    if (database.isOpen) {
      await database.setSetting('theme_mode', mode.name);
    }
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
    await database.withCatalogFiles(() async {
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
    });
  }

  Future<void> removeCatalogIcon(String tier, String sectionName) async {
    await database.withCatalogFiles(() async {
      final old = await database.getCatalogIcon(tier, sectionName);
      await database.removeCatalogIcon(tier, sectionName);
      if (old != null) await _deleteManagedIcon(old.localPath);
    });
  }

  Future<void> _deleteManagedIcon(String filePath) async {
    try {
      final root = path.normalize(imageStorage.rootPath);
      final target = path.normalize(filePath);
      if (!path.isWithin(root, target)) return;
      final mappings = await database.listCatalogIcons();
      if (mappings.any((m) => path.normalize(m.localPath) == target)) return;
      if (await database.referencesImage(filePath)) return;
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
    _disposed = true;
    _clearPendingAutomaticSync();
    _cancelAutomaticTimers();
    syncSession.invalidateDecision();
    cancelSync();
    WidgetsBinding.instance.removeObserver(this);
    _automaticSyncTimer?.cancel();
    unawaited(() async {
      await catalog.discardEdits();
      await recovery.stop();
      await database.close();
    }());
    _http.close();
    super.dispose();
  }
}
