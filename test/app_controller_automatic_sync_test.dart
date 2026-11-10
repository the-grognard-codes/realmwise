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
  late _Controller controller;
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
    controller = _Controller(
      googleDriveProvider: provider,
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

  test(
    'an edit during export is uploaded by a follow-up automatic run',
    () async {
      controller.retryDebounce = const Duration(milliseconds: 20);
      controller.holdExport = true;
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await controller.exported.future;
      await controller.database.databaseHandle.insert('works', {
        'title': 'Later edit',
      });
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller.releaseExport.complete();
      await _until(() => provider.uploads == 2 && !controller.isSyncing);
      expect(controller.automaticSyncError, isNull);
      final uploaded = File('${dir.path}/uploaded.realmwise');
      await uploaded.writeAsBytes(provider.payloads.last);
      final extracted = '${dir.path}/uploaded.db';
      await controller.bundles.extractDatabase(uploaded.path, extracted);
      final db = await databaseFactory.openDatabase(extracted);
      try {
        expect((await db.query('works')).single['title'], 'Later edit');
      } finally {
        await db.close();
      }
    },
  );

  test(
    'a debounce during manual sync retries without exporting or an error',
    () async {
      controller.retryDebounce = const Duration(milliseconds: 20);
      provider.holdUpload = true;
      controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
          .copyWith(
            revision: 'r1',
            contentHash: 'h1',
            lastSuccessfulLocalFingerprint: 'previous',
          );
      final manual = controller.syncNow();
      await provider.uploadStarted.future;
      final exports = controller.exports;
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      final schedules = controller.schedules;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(controller.schedules, schedules);
      expect(controller.exports, exports);
      expect(controller.automaticSyncError, isNull);
      provider.holdUpload = false;
      provider.releaseUpload.complete();
      await manual;
      await _until(
        () =>
            controller.exports > exports &&
            controller.automaticSyncLastSuccess != null,
      );
      expect(controller.automaticSyncError, isNull);
      expect(provider.uploads, 1);
    },
  );

  test(
    'manual sync queued during automatic export is a retry, not an error',
    () async {
      controller.retryDebounce = const Duration(milliseconds: 20);
      controller.holdExport = true;
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await controller.exported.future;
      controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
          .copyWith(
            revision: 'r1',
            contentHash: 'h1',
            lastSuccessfulLocalFingerprint: 'previous',
          );
      final manual = controller.syncNow();
      controller.releaseExport.complete();
      await manual;
      await _until(() => controller.automaticSyncLastSuccess != null);
      expect(controller.automaticSyncError, isNull);
      expect(controller.exports, greaterThanOrEqualTo(3));
    },
  );

  test(
    'background flush retains edits whose debounce fired during export',
    () async {
      controller.holdExport = true;
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await controller.exported.future;
      await controller.database.databaseHandle.insert('works', {
        'title': 'Background edit',
      });
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      controller.releaseExport.complete();
      await _until(() => provider.uploads == 2 && !controller.isSyncing);
      expect(controller.exports, 2);
      expect(controller.automaticSyncError, isNull);
      controller.didChangeAppLifecycleState(AppLifecycleState.detached);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.exports, 2);
    },
  );

  test(
    'disable drops a pending background flush while the active run drains',
    () async {
      controller.holdExport = true;
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await controller.exported.future;
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      final disabling = controller.setAutomaticSyncEnabled(false);
      controller.releaseExport.complete();
      await disabling;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.exports, 1);
      expect(provider.uploads, 0);
    },
  );

  test(
    'an edit during manual upload is sent by one completion-triggered run',
    () async {
      controller.retryDebounce = const Duration(milliseconds: 20);
      provider.holdUpload = true;
      controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
          .copyWith(
            revision: 'r1',
            contentHash: 'h1',
            lastSuccessfulLocalFingerprint: 'previous',
          );
      final manual = controller.syncNow();
      await provider.uploadStarted.future;
      await controller.database.databaseHandle.insert('works', {
        'title': 'During manual',
      });
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      provider.holdUpload = false;
      provider.releaseUpload.complete();
      await manual;
      await _until(() => provider.uploads == 2 && !controller.isSyncing);
      expect(controller.exports, 2);
      expect(controller.automaticSyncError, isNull);
    },
  );

  test('close still drains an export after an overlapping debounce', () async {
    controller.holdExport = true;
    controller.scheduleAutomaticSync(debounce: Duration.zero);
    await controller.exported.future;
    controller.scheduleAutomaticSync(debounce: Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    var closed = false;
    final closing = controller.closeDatabase().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse);
    expect(controller.database.isOpen, isTrue);
    controller.releaseExport.complete();
    await closing;
    expect(controller.database.isOpen, isFalse);
  });

  test(
    'disable signals the automatic transfer before waiting for its upload',
    () async {
      provider.holdUpload = true;
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await provider.uploadStarted.future;
      final token = controller.syncCoordinator.activeCancellation!;
      final disabling = controller.setAutomaticSyncEnabled(false);
      expect(token.isCancelled, isTrue);
      provider.releaseUpload.complete();
      await disabling;
      expect(storage.value!.automaticSyncEnabled, isFalse);
      expect(storage.value!.automaticSchedulerState, 'disabled');
      expect(controller.automaticSyncError, isNull);
    },
  );

  test(
    'disable cancels automatic work queued behind renewal before export',
    () async {
      provider.holdRenewal = true;
      renewal.fire();
      await provider.renewalStarted.future;
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final disabling = controller.setAutomaticSyncEnabled(false);
      provider.releaseRenewal.complete();
      await disabling;
      expect(controller.exports, 0);
      expect(provider.uploads, 0);
      expect(storage.value!.automaticSyncEnabled, isFalse);
    },
  );

  test('disable preserves manual transfer; connect fails busy before authentication', () async {
    provider.holdUpload = true;
    controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
        .copyWith(
          revision: 'r1',
          contentHash: 'h1',
          lastSuccessfulLocalFingerprint: 'previous',
        );
    final sync = controller.syncNow();
    await provider.uploadStarted.future;
    final token = controller.syncCoordinator.activeCancellation!;
    final authentications = provider.authentications;
    await expectLater(
      controller.connectGoogleDrive(),
      throwsA(isA<SyncBusyException>()),
    );
    expect(provider.authentications, authentications);
    final disabling = controller.setAutomaticSyncEnabled(false);
    expect(token.isCancelled, isFalse);
    provider.releaseUpload.complete();
    await sync;
    await disabling;
    expect(storage.value!.automaticSyncEnabled, isFalse);
  });

  test(
    'minimize without a pending debounce does not export or upload',
    () async {
      controller.scheduleAutomaticSync(debounce: Duration.zero);
      while (controller.automaticSyncLastSuccess == null) {
        await Future<void>.delayed(Duration.zero);
      }
      final exports = controller.exports, uploads = provider.uploads;
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(controller.exports, exports);
      expect(provider.uploads, uploads);
    },
  );

  test(
    'takeover waits for a stale lease loss and retains the new ownership',
    () async {
      final bundle = '${dir.path}/takeover.realmwise';
      await controller.exportDeviceBundle(bundle);
      final fingerprint = (await controller.bundles.validateBundle(bundle))
          .contentFingerprint;
      controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
          .copyWith(
            revision: 'r1',
            contentHash: 'h1',
            lastSuccessfulLocalFingerprint: fingerprint,
          );
      provider.holdRenewal = true;
      provider.loseOnRenewal = true;
      renewal.fire();
      await provider.renewalStarted.future;
      final takeover = controller.takeOverAutomaticSync();
      await Future<void>.delayed(Duration.zero);
      expect(provider.takeovers, 0);
      provider.releaseRenewal.complete();
      await takeover;
      expect(provider.takeovers, 1);
      expect(controller.automaticSyncEnabled, isTrue);
      expect(controller.automaticSyncOwnershipValid, isTrue);
      expect(storage.value!.leaseToken, 'takeover-1');
    },
  );

  test(
    'disable waits for takeover validation without stale re-enable',
    () async {
      final bundle = '${dir.path}/validation.realmwise';
      await controller.exportDeviceBundle(bundle);
      final fingerprint = (await controller.bundles.validateBundle(bundle))
          .contentFingerprint;
      controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
          .copyWith(
            revision: 'r1',
            contentHash: 'h1',
            lastSuccessfulLocalFingerprint: fingerprint,
          );
      provider.holdMetadata = true;
      final takeover = controller.takeOverAutomaticSync();
      await provider.metadataStarted.future;
      final disabling = controller.setAutomaticSyncEnabled(false);
      provider.releaseMetadata.complete();
      await takeover;
      await disabling;
      expect(storage.value!.automaticSyncEnabled, isFalse);
      expect(controller.automaticSyncOwnershipValid, isFalse);
      expect(renewal.isActive, isFalse);
    },
  );

  for (final setting in ['automatic', 'images']) {
    test(
      '$setting setting waits for renewal and remains persisted afterward',
      () async {
        provider.holdRenewal = true;
        renewal.fire();
        await provider.renewalStarted.future;
        final changing = setting == 'automatic'
            ? controller.setAutomaticSyncEnabled(false)
            : controller.setIncludePersonalImagesInBundles(true);
        await Future<void>.delayed(Duration.zero);
        expect(provider.releases, 0);
        provider.releaseRenewal.complete();
        await changing;
        if (setting == 'automatic') {
          expect(controller.automaticSyncEnabled, isFalse);
          expect(storage.value!.automaticSyncEnabled, isFalse);
          expect(storage.value!.automaticSchedulerState, 'disabled');
          expect(storage.value!.leaseToken, isNull);
          expect(renewal.isActive, isFalse);
          expect(provider.releases, 1);
        } else {
          expect(storage.value!.includePersonalImages, isTrue);
          expect(controller.includePersonalImagesInBundles, isTrue);
          expect(storage.value!.leaseExpiresAt, provider.lease!.expiresAt);
          expect(storage.value!.automaticSyncEnabled, isTrue);
        }
      },
    );
  }

  test('minimize flushes the pending upload once and stops renewal', () async {
    controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
        .copyWith(
          revision: 'r1',
          contentHash: 'h1',
          lastSuccessfulLocalFingerprint: 'previous',
        );
    provider.holdUpload = true;
    controller.scheduleAutomaticSync();
    controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await provider.uploadStarted.future;
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    provider.releaseUpload.complete();
    while (controller.automaticSyncLastSuccess == null) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(provider.uploads, 1);
    expect(renewal.isActive, isFalse);
  });

  test(
    'restore through inactive refreshes an expired lease and restarts renewal',
    () async {
      controller.automaticSyncOwnershipValid = false;
      final previousTimer = renewal;
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      now = now.add(const Duration(minutes: 25));
      controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(provider.lease!.isValidAt(now), isTrue);
      expect(identical(renewal, previousTimer), isFalse);
      expect(renewal.isActive, isTrue);
    },
  );

  test(
    'desktop refocus keeps the timer without provider lease calls',
    () async {
      final reads = provider.leaseReads;
      for (var i = 0; i < 20; i++) {
        controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      }
      await Future<void>.delayed(Duration.zero);
      expect(provider.leaseReads, reads);
      expect(provider.renewals, 0);
      expect(renewal.isActive, isTrue);
      now = now.add(const Duration(minutes: 5));
      renewal.fire();
      await Future<void>.delayed(Duration.zero);
      expect(provider.renewals, 1);
    },
  );

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
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
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
    controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
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

  test(
    'unchanged fingerprint skips changed bundle bytes after lease validation',
    () async {
      await controller.syncCoordinator.automaticUpload(
        Uint8List.fromList([1]),
        localFingerprint: 'local',
      );
      final renewals = provider.renewals;
      await controller.syncCoordinator.automaticUpload(
        Uint8List.fromList([2]),
        localFingerprint: 'local',
      );
      expect(provider.uploads, 1);
      expect(provider.renewals, renewals + 1);
      provider.loseOnRead = true;
      await expectLater(
        controller.syncCoordinator.automaticUpload(
          Uint8List.fromList([3]),
          localFingerprint: 'local',
        ),
        throwsA(isA<SyncLeaseLostException>()),
      );
      expect(provider.uploads, 1);
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
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
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

class _Controller extends AppController {
  _Controller({
    super.tokenStorage,
    super.imageRootPathOverride,
    super.clock,
    super.periodicTimer,
    super.googleDriveProvider,
  });
  int exports = 0;
  bool holdExport = false;
  Duration? retryDebounce;
  int schedules = 0;
  final exported = Completer<void>(), releaseExport = Completer<void>();
  @override
  void scheduleAutomaticSync({Duration debounce = const Duration(seconds: 5)}) {
    schedules++;
    super.scheduleAutomaticSync(
      debounce: debounce == const Duration(seconds: 5)
          ? retryDebounce ?? debounce
          : debounce,
    );
  }

  @override
  Future<void> exportDeviceBundle(String outputPath) async {
    exports++;
    await super.exportDeviceBundle(outputPath);
    if (holdExport && !exported.isCompleted) {
      exported.complete();
      await releaseExport.future;
    }
  }
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
  final payloads = <Uint8List>[];
  bool loseOnRead = false, holdRenewal = false;
  int leaseReads = 0, takeovers = 0, authentications = 0;
  bool holdMetadata = false;
  final metadataStarted = Completer<void>(),
      releaseMetadata = Completer<void>();
  final renewalStarted = Completer<void>(), releaseRenewal = Completer<void>();
  bool loseOnRenewal = false;
  bool holdUpload = false;
  final uploadStarted = Completer<void>(), releaseUpload = Completer<void>();
  @override
  String get provider => 'fake';
  @override
  Future<SyncAuthSession> authenticate() async {
    authentications++;
    return const SyncAuthSession(accountId: 'account');
  }

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
      metadataStarted.complete();
      await releaseMetadata.future;
    }
    return const SyncRemoteMetadata(
      revision: SyncRevision('r1'),
      contentHash: 'h1',
    );
  }

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession session,
    SyncRemoteTarget target,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) async {
    uploads++;
    payloads.add(payload);
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
    leaseReads++;
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
  }) async {
    if (takeover) takeovers++;
    return lease = SyncLease(
      catalogIdentity: catalogIdentity,
      ownerDeviceId: deviceId,
      ownerDeviceName: deviceName,
      generation: takeovers == 0 ? 'generation' : 'takeover-$takeovers',
      token: takeovers == 0 ? 'token' : 'takeover-$takeovers',
      issuedAt: clock(),
      expiresAt: clock().add(duration),
      lastRenewedAt: clock(),
    );
  }

  @override
  Future<SyncLease> renewLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity, {
    required String deviceId,
    required String token,
    required Duration duration,
  }) async {
    if (holdRenewal) {
      renewalStarted.complete();
      await releaseRenewal.future;
    }
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

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for sync');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
