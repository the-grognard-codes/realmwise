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
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('automatic_sync_');
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
    await controller.syncCoordinator.connect(
      provider,
      await controller.database.ensureCatalogIdentity(),
    );
    controller.deviceId = 'device';
    controller.deviceName = 'Desktop';
    await controller.setAutomaticSyncEnabled(true);
  });
  tearDown(() async {
    await controller.closeDatabase();
    controller.dispose();
    await dir.delete(recursive: true);
  });

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
  });

  test('lease remains enabled through 25 idle foreground minutes', () async {
    final token = provider.lease!.token;
    for (var minute = 5; minute <= 25; minute += 5) {
      now = DateTime.utc(2026).add(Duration(minutes: minute));
      renewal.fire();
      await Future<void>.delayed(Duration.zero);
      expect(controller.automaticSyncEnabled, isTrue);
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

  test('close cancels renewal', () async {
    await controller.closeDatabase();
    expect(renewal.isActive, isFalse);
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
  int renewals = 0, uploads = 0;
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
  ) async => owner == 'device' ? lease : null;
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
  }) async {}
}

class _Tokens implements TokenStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}
