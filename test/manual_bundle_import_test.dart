import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
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
        (call) async => Directory.systemTemp.path,
      );
  late Directory dir;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('manual_import_');
  });
  tearDown(() => dir.delete(recursive: true));

  test('replaces active database and leaves recoverable backup', () async {
    final controller = AppController(
      tokenStorage: _MemoryTokenStorage(),
      imageRootPathOverride: p.join(dir.path, 'images'),
    );
    final active = p.join(dir.path, 'active.db');
    await controller.openDatabase(active, remember: false);
    await controller.database.databaseHandle.insert('works', {'title': 'Old'});
    final bundle = p.join(dir.path, 'bundle.realmwise');
    await controller.exportDeviceBundle(bundle);
    await controller.database.databaseHandle.insert('works', {'title': 'New'});
    await controller.restoreDeviceBundle(bundle);
    final rows = await controller.database.databaseHandle.query('works');
    expect(rows.map((r) => r['title']), contains('Old'));
    expect(rows.map((r) => r['title']), isNot(contains('New')));
    final backups = Directory(p.join(dir.path, 'backups'));
    expect(
      backups.listSync().where((e) => e.path.endsWith('.backup.db')),
      isNotEmpty,
    );
    controller.dispose();
  });

  test('invalid bundle fails before replacement and preserves active database', () async {
    final controller = AppController(
      tokenStorage: _MemoryTokenStorage(),
      imageRootPathOverride: p.join(dir.path, 'images'),
    );
    final active = p.join(dir.path, 'active.db');
    await controller.openDatabase(active, remember: false);
    await controller.database.databaseHandle.insert('works', {'title': 'Keep'});
    final invalid = p.join(dir.path, 'invalid.realmwise');
    await File(invalid).writeAsString('not zip');
    await expectLater(
      controller.restoreDeviceBundle(invalid),
      throwsA(isA<FormatException>()),
    );
    expect((await controller.database.databaseHandle.query('works')).single['title'], 'Keep');
    controller.dispose();
  });

  test(
    'bundle restore clears a live sync session when catalog setup is absent',
    () async {
    final provider = _FakeSyncProvider();
    final controller = AppController(
      syncProvider: provider,
      tokenStorage: _MemoryTokenStorage(),
      imageRootPathOverride: p.join(dir.path, 'images'),
    );
    controller.syncCoordinator = SyncCoordinator(
      metadataStorage: SharedPreferencesSyncMetadataStorage(
        await SharedPreferences.getInstance(),
      ),
    );
    final active = p.join(dir.path, 'active.db');
    await controller.openDatabase(active, remember: false);
    await controller.selectProvider(provider);
    controller.syncCoordinator.provider = provider;
    controller.syncCoordinator.session = const SyncAuthSession(
      accountId: 'account',
    );
    controller.syncCoordinator.target = const SyncRemoteTarget(
      id: 'target',
      name: 'Target',
    );
    controller.syncMetadata = null;

    final bundle = p.join(dir.path, 'bundle.realmwise');
    await controller.exportDeviceBundle(bundle);
    await controller.restoreDeviceBundle(bundle);

    expect(controller.selectedProvider, isNull);
    expect(controller.syncMetadata, isNull);
    expect(controller.syncCoordinator.isConnected, isFalse);
    controller.dispose();
    },
  );
}

class _MemoryTokenStorage implements TokenStorage {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}

class _FakeSyncProvider implements SyncProvider {
  @override
  String get provider => 'fake';

  @override
  Future<SyncAuthSession> authenticate() async =>
      const SyncAuthSession(accountId: 'account');

  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(
    SyncAuthSession session,
  ) async => const [];

  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession session,
    SyncRemoteTarget target,
  ) async => null;

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession session,
    SyncRemoteTarget target,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) => throw UnimplementedError();

  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession session,
    SyncRemoteTarget target, {
    SyncPrecondition? precondition,
  }) => throw UnimplementedError();
}
