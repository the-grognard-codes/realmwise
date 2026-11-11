import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
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
    controller = _SchedulingController(directory.path, provider: provider);
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

  for (final name in ['my_realmwise', 'custom_catalog']) {
    test('startup restores $name after an interrupted replacement', () async {
      final originalPath = controller.database.databasePath;
      await controller.database.databaseHandle.insert('works', {
        'title': 'Original before crash',
      });
      await controller.closeDatabase();
      controller.dispose();
      final saved = '${directory.path}/$name.db';
      await File(originalPath).rename(saved);
      final olderRollback = '$saved.rollback-9.tmp';
      await File(olderRollback).writeAsBytes([1, 2, 3]);
      final rollback = '$saved.rollback-10.tmp';
      await File(saved).rename(rollback);
      final ready = '$saved.replace-10.tmp.ready';
      await controller.bundles.extractDatabase(bundle, ready);
      final marker = File('$saved.recovery-review.json');
      final markerContents = jsonEncode({'originalPath': rollback});
      await marker.writeAsString(markerContents, flush: true);
      SharedPreferences.setMockInitialValues({'last_database_path': saved});
      controller = _SchedulingController(directory.path);

      await controller.initialize();

      expect(controller.error, isNull);
      expect(controller.activeDatabasePath, File(saved).absolute.path);
      expect(
        await controller.database.databaseHandle.query('works'),
        contains(containsPair('title', 'Original before crash')),
      );
      expect(await File(rollback).exists(), isFalse);
      expect(await File(olderRollback).readAsBytes(), [1, 2, 3]);
      final restoredMarker = jsonDecode(await marker.readAsString());
      expect(restoredMarker['originalPath'], saved);
      expect(restoredMarker['originalRestored'], isTrue);
      expect(controller.recoveryWarning?.originalPath, saved);
      expect(
        controller.recoveryWarning?.message,
        contains('original catalog was restored'),
      );
      expect(
        controller.recoveryWarning?.message,
        contains('interrupted import was discarded'),
      );
      expect(controller.recoveryWarning?.message, isNot(contains(rollback)));
      await controller.recovery.loadWarning();
      expect(
        controller.recoveryWarning?.message,
        contains('original catalog was restored'),
      );
      expect(await File(ready).exists(), isFalse);
    });
  }

  for (final reason in ['no review marker', 'cleanup already pending']) {
    test('startup falls back when rollback has $reason', () async {
      final saved = controller.database.databasePath;
      await controller.closeDatabase();
      controller.dispose();
      final rollback = '$saved.rollback-10.tmp';
      await File(saved).rename(rollback);
      final original = await File(rollback).readAsBytes();
      if (reason == 'cleanup already pending') {
        await File('$saved.recovery-review.json')
            .writeAsString(jsonEncode({'originalPath': rollback}));
        await File('$rollback.cleanup-pending').writeAsString('');
      }
      SharedPreferences.setMockInitialValues({'last_database_path': saved});
      controller = _SchedulingController(directory.path);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      try {
        await controller.initialize();

        expect(controller.error, isNull);
        expect(
          controller.activeDatabasePath,
          '${directory.path}${Platform.pathSeparator}my_realmwise.db',
        );
        expect(await File(saved).exists(), isFalse);
        expect(await File(rollback).readAsBytes(), original);
        expect(
          await controller.database.databaseHandle.query('works'),
          isEmpty,
        );
      } finally {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => Directory.systemTemp.path,
        );
      }
    });
  }

  test(
    'manual sync cannot export or upload an unacknowledged catalog',
    () async {
      final active = controller.database.databasePath;
      await controller.database.databaseHandle.insert('works', {
        'title': 'Pending local edit',
      });
      await File('$active.recovery-review.json')
          .writeAsString('{"originalPath":"original.rollback.tmp"}');
      await controller.recovery.loadWarning();
      final exports = controller.exports;
      await expectLater(
        controller.syncNow(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('acknowledge'),
          ),
        ),
      );
      expect(controller.exports, exports);
      expect(provider.uploads, 0);
      await controller.acknowledgeRecoveryWarning();
      await controller.syncNow();
      expect(controller.exports, greaterThan(exports));
      expect(provider.uploads, 1);
    },
  );

  test(
    'a retained conflict choice cannot upload an unreviewed catalog',
    () async {
      final active = controller.database.databasePath;
      await File('$active.recovery-review.json')
          .writeAsString('{"originalPath":"original.rollback.tmp"}');
      await controller.recovery.loadWarning();
      final exports = controller.exports;
      await expectLater(
        controller.resolveSyncDecision(
          SyncConflictChoice.uploadReplaceRemote,
          decision: const SyncClassificationResult(
            SyncClassification.divergent,
            remote: _Provider.remote,
          ),
          localFingerprint: fingerprint,
        ),
        throwsStateError,
      );
      expect(controller.exports, exports);
      expect(provider.uploads, 0);
    },
  );

  for (final operation in ['restore', 'download']) {
    test('successful $operation clears an earlier warning', () async {
      final active = controller.database.databasePath;
      final point = await controller.recovery.snapshot(SnapshotKind.manual);
      await File('$active.recovery-review.json')
          .writeAsString('{"originalPath":"original.rollback.tmp"}');
      await controller.recovery.loadWarning();
      if (operation == 'restore') {
        final result = await controller.restoreFromBackup(point);
        expect(result.needsAcknowledgement, isFalse);
        expect(controller.schedules, greaterThan(0));
      } else {
        expect(
          await controller.downloadRemoteBundle(
            expectedRemote: _Provider.remote,
          ),
          isTrue,
        );
        expect(controller.syncCoordinator.isConnected, isTrue);
        expect(
          controller.syncCoordinator.metadata!.lastSuccessfulLocalFingerprint,
          fingerprint,
        );
      }
      expect(controller.recoveryWarning, isNull);
      expect(await File('$active.recovery-review.json').exists(), isFalse);
    });
  }

  for (final operation in ['import', 'restore', 'download']) {
    test(
      '$operation exposes retained replacement without reporting failure',
      () async {
        final active = controller.database.databasePath;
        final point = await controller.recovery.snapshot(SnapshotKind.manual);
        await controller.recovery.stop();
        controller.recoveryOverride = CatalogRecovery(
          database: controller.database,
          reopen: (path) async {
            await controller.database.open(path);
            await controller.recovery.loadWarning();
          },
          rehydrate: () async => throw StateError('rehydrate failed'),
          deleteFile: (file) async {
            if (file.path == active)
              throw const FileSystemException('delete blocked');
            await file.delete();
          },
          renameFile: (file, target) async {
            if (file.path.contains('.rollback-'))
              throw const FileSystemException('rename blocked');
            return file.rename(target);
          },
        );
        if (operation == 'download') {
          expect(
            await controller.downloadRemoteBundle(
              expectedRemote: _Provider.remote,
            ),
            isTrue,
          );
        } else {
          final result = operation == 'import'
              ? await controller.restoreDeviceBundle(bundle)
              : await controller.restoreFromBackup(point);
          expect(result.needsAcknowledgement, isTrue);
        }
        expect(controller.isOpen, isTrue);
        expect(controller.recoveryWarning, isNotNull);
        expect(
          await File(controller.recoveryWarning!.originalPath).exists(),
          isTrue,
        );
        expect(controller.schedules, 0);
      },
    );
  }

  test('recovery warning fences refresh, queued timers and lifecycle until acknowledgement', () async {
    controller.useRealScheduler = true;
    controller.automaticSyncEnabled = true;
    controller.automaticSyncOwnershipValid = true;
    // This timer was already queued when recovery recorded its warning.
    controller.scheduleAutomaticSync(
      debounce: const Duration(milliseconds: 50),
    );
    final active = controller.database.databasePath;
    await File('$active.recovery-review.json')
        .writeAsString('{"originalPath":"original.rollback.tmp"}');
    await controller.recovery.loadWarning();
    final exports = controller.exports;
    controller.observeCatalogRecords(await controller.database.listRecords());
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(controller.exports, exports);
    await controller.closeDatabase();
    await controller.openDatabase(active, remember: false);
    expect(controller.recoveryWarning, isNotNull);
    controller.automaticSyncEnabled = true;
    controller.automaticSyncOwnershipValid = true;
    controller.scheduleAutomaticSync(debounce: Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.exports, exports);
    await controller.acknowledgeRecoveryWarning();
    expect(controller.recoveryWarning, isNull);
    expect(await File('$active.recovery-review.json').exists(), isFalse);
    controller.automaticSyncEnabled = false;
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    controller.automaticSyncEnabled = true;
    controller.automaticSyncOwnershipValid = true;
    controller.scheduleAutomaticSync(debounce: Duration.zero);
    for (
      var attempt = 0;
      attempt < 100 && controller.exports == exports;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.exports, greaterThan(exports));
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

  test('remote replacement defers scheduling through rebind', () async {
    final eligible = controller.syncCoordinator.metadata!;
    await controller.downloadRemoteBundle(expectedRemote: _Provider.remote);
    expect(controller.schedules, 0);
    expect(controller.syncCoordinator.metadata!.automaticSyncEnabled, isFalse);
    // Rebind intentionally disabled ownership. A later plain import may resume
    // only when its normal persisted setup is eligible again.
    await controller.syncCoordinator.metadataStorage.write(eligible);
    await controller.restoreDeviceBundle(bundle);
    expect(controller.schedules, 1);
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
  _SchedulingController(String root, {SyncProvider? provider})
    : super(
        tokenStorage: _Tokens(),
        imageRootPathOverride: '$root/images',
        syncProvider: provider,
      );
  int schedules = 0;
  CatalogRecovery? recoveryOverride;
  @override
  CatalogRecovery get recovery => recoveryOverride ?? super.recovery;
  int exports = 0;
  bool useRealScheduler = false;
  @override
  Future<void> exportDeviceBundle(String outputPath) {
    exports++;
    return super.exportDeviceBundle(outputPath);
  }

  @override
  void scheduleAutomaticSync({Duration debounce = const Duration(seconds: 5)}) {
    schedules++;
    if (useRealScheduler) super.scheduleAutomaticSync(debounce: debounce);
  }
}

class _Provider implements SyncProvider, SyncLeaseProvider {
  int uploads = 0;
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
  }) async {
    uploads++;
    return const SyncUploadResult(metadata: remote);
  }

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
