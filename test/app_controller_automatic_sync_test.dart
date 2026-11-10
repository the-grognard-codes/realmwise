import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/services/sync_coordinator.dart';
import 'package:realmwise/services/sync_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => Directory.systemTemp.path,
      );
  late Directory dir;
  late AppController controller;
  late _LeaseProvider provider;
  late DateTime now;
  late _ManualTimer renewal;
  late _MetadataStorage storage;
  var disposed = false;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('automatic_sync_');
    disposed = false;
    now = DateTime.utc(2026);
    provider = _LeaseProvider(() => now);
    controller = AppController(
      tokenStorage: _Tokens(),
      imageRootPathOverride: '${dir.path}/images',
      clock: () => now,
      periodicTimer: (duration, callback) {
        expect(duration, const Duration(minutes: 5));
        return renewal = _ManualTimer(callback);
      },
    );
    await controller.openDatabase('${dir.path}/catalog.db', remember: false);
    storage = _MetadataStorage();
    controller.syncCoordinator = SyncCoordinator(
      metadataStorage: storage,
      clock: () => now,
    );
    await controller.syncCoordinator.connect(
      provider,
      await controller.database.ensureCatalogIdentity(),
    );
    controller.deviceId = 'device';
    controller.deviceName = 'Desktop';
    await controller.setAutomaticSyncEnabled(true);
  });
  tearDown(() async {
    if (!disposed) {
      await controller.closeDatabase();
      controller.dispose();
    }
    await dir.delete(recursive: true);
  });

  test('inactive keeps pending upload and renews for 25 minutes', () async {
    controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
        .copyWith(
          revision: 'r1',
          contentHash: 'h1',
          lastSuccessfulLocalFingerprint: 'previous',
        );
    provider.holdUpload = true;
    controller.scheduleAutomaticSync(debounce: Duration.zero);
    controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(renewal.isActive, isTrue);
    await provider.uploadStarted.future;
    provider.releaseUpload.complete();
    while (controller.automaticSyncLastSuccess == null) {
      await Future<void>.delayed(Duration.zero);
    }
    for (var minute = 5; minute <= 25; minute += 5) {
      now = DateTime.utc(2026).add(Duration(minutes: minute));
      renewal.fire();
      await Future<void>.delayed(Duration.zero);
      expect(provider.lease!.isValidAt(now), isTrue);
    }
    expect(provider.uploads, 1);
    expect(provider.renewals, greaterThanOrEqualTo(5));
  });

  for (final action in ['close', 'disconnect']) {
    test('$action cancels upload before waiting on queued renewal', () async {
      provider.holdUpload = true;
      controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
          .copyWith(
            revision: 'r1',
            contentHash: 'h1',
            lastSuccessfulLocalFingerprint: 'previous',
          );
      final sync = controller.syncNow();
      final syncResult = sync.then<void>((_) {}, onError: (Object _) {});
      await provider.uploadStarted.future;
      final token = controller.syncCoordinator.activeCancellation!;
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      final closing = action == 'close'
          ? controller.closeDatabase()
          : controller.disconnectGoogleDrive();
      try {
        expect(token.isCancelled, isTrue);
        expect(renewal.isActive, isFalse);
      } finally {
        provider.releaseUpload.complete();
        await syncResult;
        await closing;
      }
    });
  }

  test('disconnect cancels pending upload and renewal', () async {
    controller.scheduleAutomaticSync(debounce: Duration.zero);
    await controller.disconnectGoogleDrive();
    renewal.fire();
    await Future<void>.delayed(Duration.zero);
    expect(renewal.isActive, isFalse);
    expect(provider.uploads, 0);
    expect(provider.renewals, 0);
  });

  test('dispose cancels pending upload and renewal', () async {
    controller.scheduleAutomaticSync(debounce: Duration.zero);
    controller.dispose();
    disposed = true;
    renewal.fire();
    await Future<void>.delayed(Duration.zero);
    expect(renewal.isActive, isFalse);
    expect(provider.uploads, 0);
    expect(provider.renewals, 0);
    await controller.backups.stop();
    await controller.database.close();
  });

  for (final phase in ['read', 'renew']) {
    test(
      'lease loss during $phase persists once without releasing remote',
      () async {
        final before = storage.writes;
        provider.loseOnRead = phase == 'read';
        provider.loseOnRenewal = phase == 'renew';
        renewal.fire();
        await Future<void>.delayed(Duration.zero);
        expect(storage.writes, before + 1);
        expect(provider.releases, 0);
        expect(storage.value!.automaticSchedulerState, 'lease_lost');
        expect(storage.value!.leaseToken, isNull);
        expect(controller.automaticSyncEnabled, isFalse);
        expect(renewal.isActive, isFalse);
      },
    );
  }

  test(
    'expired lease revalidation never overwrites remote-only changes',
    () async {
      controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
          .copyWith(
            revision: 'old',
            contentHash: 'old-hash',
            lastSuccessfulLocalFingerprint: 'local',
          );
      now = now.add(const Duration(minutes: 25));
      await expectLater(
        controller.syncCoordinator.automaticUpload(
          Uint8List.fromList([1]),
          localFingerprint: 'local',
        ),
        throwsA(isA<SyncConflictException>()),
      );
      expect(provider.uploads, 0);
      expect(controller.syncCoordinator.metadata!.revision, 'old');
      expect(
        controller.syncCoordinator.metadata!.automaticSchedulerState,
        'conflict',
      );
    },
  );

  test('image policy preserves automatic metadata', () async {
    final before = controller.syncCoordinator.metadata!;
    await controller.setIncludePersonalImagesInBundles(true);
    final after = controller.syncCoordinator.metadata!;
    expect(after.automaticSyncEnabled, isTrue);
    expect(after.deviceId, before.deviceId);
    expect(after.leaseToken, before.leaseToken);
    expect(after.ownershipGeneration, before.ownershipGeneration);
    expect(after.leaseExpiresAt, before.leaseExpiresAt);
    expect(after.includePersonalImages, isTrue);
    expect(after.updatedAt, now);
  });

  test('lease remains enabled through 25 idle foreground minutes', () async {
    final token = provider.lease!.token;
    for (var minute = 5; minute <= 25; minute += 5) {
      now = DateTime.utc(2026).add(Duration(minutes: minute));
      renewal.fire();
      await Future<void>.delayed(Duration.zero);
      expect(controller.automaticSyncEnabled, isTrue);
      expect(controller.syncCoordinator.metadata!.updatedAt, now);
      expect(provider.lease!.isValidAt(now), isTrue);
      expect(provider.lease!.token, token);
    }
    expect(provider.renewals, 5);
    expect(provider.uploads, 0);
  });

  test('another owner disables automatic sync and cancels renewal', () async {
    provider.owner = 'other';
    renewal.fire();
    await Future<void>.delayed(Duration.zero);
    expect(controller.automaticSyncEnabled, isFalse);
    expect(
      controller.syncCoordinator.metadata!.automaticSchedulerState,
      'lease_lost',
    );
    expect(renewal.isActive, isFalse);
  });

  test('pause cancels renewal; resume reacquires expired own lease', () async {
    controller.automaticSyncOwnershipValid = false;
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(renewal.isActive, isFalse);
    now = now.add(const Duration(minutes: 25));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(provider.lease!.isValidAt(now), isTrue);
    expect(controller.automaticSyncEnabled, isTrue);
    expect(controller.automaticSyncOwnershipValid, isTrue);
    expect(
      controller.syncCoordinator.metadata!.automaticSchedulerState,
      'needs_remote_validation',
    );
    expect(renewal.isActive, isTrue);
  });

  test(
    'ownership lost between read and renewal is persisted as lease_lost',
    () async {
      provider.loseOnRenewal = true;
      expect(await controller.syncCoordinator.refreshAutomaticLease(), isNull);
      expect(
        controller.syncCoordinator.metadata!.automaticSyncEnabled,
        isFalse,
      );
      expect(
        controller.syncCoordinator.metadata!.automaticSchedulerState,
        'lease_lost',
      );
    },
  );

  test(
    'automatic upload returns the final successful scheduler metadata',
    () async {
      final result = await controller.syncCoordinator.automaticUpload(
        Uint8List.fromList([1]),
        localFingerprint: 'local',
      );
      expect(result.automaticSchedulerState, 'ready');
      expect(result.lastAutomaticSuccessAt, now);
      expect(identical(result, controller.syncCoordinator.metadata), isTrue);
    },
  );

  test('close cancels renewal', () async {
    await controller.closeDatabase();
    expect(renewal.isActive, isFalse);
  });

  test('resume renewal waits for an in-flight manual sync', () async {
    provider.holdUpload = true;
    controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
        .copyWith(
          revision: 'r1',
          contentHash: 'h1',
          lastSuccessfulLocalFingerprint: 'previous',
        );
    final sync = controller.syncNow();
    await provider.uploadStarted.future;
    try {
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(provider.renewals, 0);
    } finally {
      provider.releaseUpload.complete();
      await sync;
    }
    await Future<void>.delayed(Duration.zero);
    expect(provider.renewals, 1);
    expect(controller.syncCoordinator.metadata!.revision, 'r1');
  });
}

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);
  final void Function(Timer) callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  void fire() {
    if (isActive) {
      tick++;
      callback(this);
    }
  }

  @override
  void cancel() => isActive = false;
}

class _LeaseProvider implements SyncProvider, SyncLeaseProvider {
  _LeaseProvider(this.clock);
  final DateTime Function() clock;
  SyncLease? lease;
  String owner = 'device';
  int renewals = 0, uploads = 0, releases = 0;
  bool loseOnRead = false;
  bool loseOnRenewal = false;
  bool holdUpload = false;
  final uploadStarted = Completer<void>(), releaseUpload = Completer<void>();
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
  ) async =>
      const SyncRemoteMetadata(revision: SyncRevision('r1'), contentHash: 'h1');
  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession session,
    SyncRemoteTarget target,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) async {
    uploads++;
    if (holdUpload) {
      uploadStarted.complete();
      await releaseUpload.future;
    }
    return const SyncUploadResult(
      metadata: SyncRemoteMetadata(
        revision: SyncRevision('r1'),
        contentHash: 'h1',
      ),
    );
  }

  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession session,
    SyncRemoteTarget target, {
    SyncPrecondition? precondition,
  }) async => throw UnimplementedError();
  @override
  Future<SyncLease?> readLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity,
  ) async {
    if (loseOnRead) throw const SyncLeaseLostException();
    return owner == 'device' ? lease : null;
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
  }) async => lease = SyncLease(
    catalogIdentity: catalogIdentity,
    ownerDeviceId: deviceId,
    ownerDeviceName: deviceName,
    generation: 'generation',
    token: 'token',
    issuedAt: clock(),
    expiresAt: clock().add(duration),
    lastRenewedAt: clock(),
  );
  @override
  Future<SyncLease> renewLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity, {
    required String deviceId,
    required String token,
    required Duration duration,
  }) async {
    if (loseOnRenewal) throw const SyncLeaseLostException();
    if (!lease!.isValidAt(clock())) throw const SyncLeaseLostException();
    renewals++;
    return acquireLease(
      session,
      target,
      catalogIdentity,
      deviceId: deviceId,
      deviceName: 'Desktop',
      duration: duration,
    );
  }

  @override
  Future<void> releaseLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity, {
    required String deviceId,
    required String token,
  }) async {
    releases++;
  }
}

class _MetadataStorage implements SyncMetadataStorage {
  int writes = 0;
  SyncMetadata? value;
  @override
  Future<SyncMetadata?> read(String identity) async => value;
  @override
  Future<void> write(SyncMetadata metadata) async {
    writes++;
    value = metadata;
  }

  @override
  Future<void> remove(String identity) async {
    value = null;
  }
}

class _Tokens implements TokenStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}
