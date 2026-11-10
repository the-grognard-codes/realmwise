import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:realmwise/services/catalog_recovery.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/services/sync_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => Directory.systemTemp.path,
      );
  late Directory directory;
  late _SchedulingController controller;
  late _Provider provider;
  late String bundle, fingerprint;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('controller_recovery_');
    provider = _Provider();
    controller = _SchedulingController(directory.path);
    await controller.openDatabase(
      '${directory.path}/catalog.db',
      remember: false,
    );
    await controller.database.databaseHandle.insert('works', {
      'title': 'Original',
    });
    bundle = '${directory.path}/catalog.realmwise';
    await controller.exportDeviceBundle(bundle);
    fingerprint = (await controller.previewDeviceBundle(bundle))
        .contentFingerprint!;
    provider.payload = Uint8List.fromList(await File(bundle).readAsBytes());
    final identity = await controller.database.ensureCatalogIdentity();
    await controller.syncCoordinator.connect(provider, identity);
    controller.syncCoordinator.metadata = SyncMetadata(
      catalogIdentity: identity,
      provider: provider.provider,
      accountId: 'account',
      remoteTargetId: 'target',
      revision: 'r1',
      contentHash: 'h1',
      lastSuccessfulLocalFingerprint: fingerprint,
      automaticSyncEnabled: true,
      deviceId: 'device',
      leaseToken: 'token',
      leaseExpiresAt: DateTime.utc(2099),
      state: SyncState.ready,
    );
    controller.deviceId = 'device';
    controller.deviceName = 'Desktop';
    await controller.syncCoordinator.metadataStorage.write(
      controller.syncCoordinator.metadata!,
    );
  });
  tearDown(() async {
    await controller.closeDatabase();
    controller.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'successful import and Settings restore resume eligible automatic sync',
    () async {
      await controller.restoreDeviceBundle(bundle);
      expect(controller.schedules, 1);
      final point = await controller.recovery.snapshot(SnapshotKind.manual);
      await controller.restoreFromBackup(point);
      expect(controller.schedules, 2);
    },
  );

  test('callback retained from a completed download cannot bypass a later activity', () async {
    final identity = await controller.database.ensureCatalogIdentity();
    await controller.downloadRemoteBundle(expectedRemote: _Provider.remote);
    final oldZone = provider.downloadZone!;
    await controller.syncCoordinator.connect(provider, identity);
    provider.holdMetadata = true;
    final validation = controller.takeOverAutomaticSync();
    await provider.entered.future;
    try {
      await expectLater(
        oldZone.run(
          () =>
              controller.downloadRemoteBundle(expectedRemote: _Provider.remote),
        ),
        throwsA(isA<SyncBusyException>()),
      );
    } finally {
      provider.release.complete();
      await validation;
    }
  });

  test('import waits for in-flight remote validation', () async {
    provider.holdMetadata = true;
    final validation = controller.takeOverAutomaticSync();
    await provider.entered.future;
    final replacing = controller.restoreDeviceBundle(bundle);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.recovery.isReplacing, isTrue);
    expect(controller.database.isOpen, isTrue);
    expect(
      (await controller.recovery.restorePoints()).where(
        (point) => point.kind == SnapshotKind.preImport,
      ),
      isEmpty,
    );
    provider.release.complete();
    await validation;
    await replacing;
    expect(controller.database.isOpen, isTrue);
  });

  test(
    'import waits for conflict resolution and preserves manual snapshots',
    () async {
      final manual = await controller.recovery.snapshot(SnapshotKind.manual);
      provider.holdDownload = true;
      final resolving = controller.resolveSyncDecision(
        SyncConflictChoice.uploadReplaceRemote,
        decision: const SyncClassificationResult(
          SyncClassification.divergent,
          remote: _Provider.remote,
        ),
        localFingerprint: fingerprint,
      );
      await provider.entered.future;
      final replacing = controller.restoreDeviceBundle(bundle);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.recovery.isReplacing, isTrue);
      expect(controller.database.isOpen, isTrue);
      provider.release.complete();
      await resolving;
      await replacing;
      final points = await controller.recovery.restorePoints();
      expect(
        points.where((point) => point.kind == SnapshotKind.preConflict),
        hasLength(1),
      );
      expect(
        points.where((point) => point.kind == SnapshotKind.preRemoteOverwrite),
        hasLength(1),
      );
      expect(await File(manual.path).exists(), isTrue);
    },
  );
}

class _SchedulingController extends AppController {
  _SchedulingController(String root)
    : super(tokenStorage: _Tokens(), imageRootPathOverride: '$root/images');
  int schedules = 0;
  @override
  void scheduleAutomaticSync({Duration debounce = const Duration(seconds: 5)}) {
    schedules++;
  }
}

class _Provider implements SyncProvider, SyncLeaseProvider {
  static const remote = SyncRemoteMetadata(
    revision: SyncRevision('r1'),
    contentHash: 'h1',
  );
  late Uint8List payload;
  Zone? downloadZone;
  bool holdMetadata = false, holdDownload = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  String get provider => 'fake';
  @override
  Future<SyncAuthSession> authenticate() async =>
      const SyncAuthSession(accountId: 'account');
  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(
    SyncAuthSession session,
  ) async => const [SyncRemoteTarget(id: 'target', name: 'Target')];
  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession session,
    SyncRemoteTarget target,
  ) async {
    if (holdMetadata) {
      entered.complete();
      await release.future;
      holdMetadata = false;
    }
    return remote;
  }

  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession session,
    SyncRemoteTarget target, {
    SyncPrecondition? precondition,
  }) async {
    downloadZone = Zone.current;
    if (holdDownload) {
      entered.complete();
      await release.future;
      holdDownload = false;
    }
    return SyncDownloadResult(payload: payload, metadata: remote);
  }

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession session,
    SyncRemoteTarget target,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) async => const SyncUploadResult(metadata: remote);
  @override
  Future<SyncLease> acquireLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity, {
    required String deviceId,
    required String deviceName,
    required Duration duration,
    bool takeover = false,
  }) async => SyncLease(
    catalogIdentity: catalogIdentity,
    ownerDeviceId: deviceId,
    ownerDeviceName: deviceName,
    generation: '1',
    token: 'token',
    issuedAt: DateTime.utc(2026),
    expiresAt: DateTime.utc(2099),
    lastRenewedAt: DateTime.utc(2026),
  );
  @override
  Future<SyncLease?> readLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity,
  ) async => null;
  @override
  Future<void> releaseLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity, {
    required String deviceId,
    required String token,
  }) async {}
  @override
  Future<SyncLease> renewLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity, {
    required String deviceId,
    required String token,
    required Duration duration,
  }) async => throw UnimplementedError();
}

class _Tokens implements TokenStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}
