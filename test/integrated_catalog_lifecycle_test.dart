import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:realmwise/services/sync_contract.dart';

class _Tokens implements TokenStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Sync extends Object implements SyncProvider {
  final started = Completer<void>(), release = Completer<void>();
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
    started.complete();
    await release.future;
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => Directory.systemTemp.path,
      );

  test('restore discards active image edits; subsequent save and export remain consistent', () async {
    final dir = await Directory.systemTemp.createTemp('integrated_catalog_');
    final controller = AppController(
      tokenStorage: _Tokens(),
      imageRootPathOverride: '${dir.path}/images',
    );
    try {
      await controller.openDatabase('${dir.path}/catalog.db', remember: false);
      final a = File('${controller.imageStorage.rootPath}/a.jpg'),
          b = File('${controller.imageStorage.rootPath}/b.jpg');
      await a.writeAsBytes([1, 2, 3]);
      await b.writeAsBytes([4, 5, 6]);
      final saved = await controller.database.saveRecord(
        CatalogRecord(
          work: BookWork(title: 'Original'),
          copies: [UserCopy()],
          images: [
            BookImage(localPath: a.path, isCover: true),
            BookImage(localPath: b.path, caption: 'Second'),
          ],
        ),
      );
      controller.includePersonalImagesInBundles = true;
      final bundle = '${dir.path}/original.realmwise';
      await controller.exportDeviceBundle(bundle);
      final edit = controller.catalog.beginEditing(saved);
      await edit.addFile(a.path, label: 'Unsaved');
      final staged = edit.record.images.last.localPath;
      edit.setCover(1);
      await controller.restoreDeviceBundle(bundle);
      expect(controller.activeDatabasePath, '${dir.path}/catalog.db');
      expect(await File(staged).exists(), isFalse);
      await expectLater(edit.save(), throwsStateError);
      final restored = await controller.database.getRecord(saved.work.id!);
      expect(restored.images, hasLength(2));
      final next = controller.catalog.beginEditing(restored)..setCover(1);
      final updated = await next.save();
      expect(updated.cover!.caption, 'Second');
      final exported = '${dir.path}/updated.realmwise';
      await controller.exportDeviceBundle(exported);
      expect(
        (await controller.bundles.validateBundle(exported)).assets,
        hasLength(2),
      );
    } finally {
      await controller.closeDatabase();
      controller.dispose();
      await dir.delete(recursive: true);
    }
  });

  test('controller import drains an actual in-flight sync before replacing its catalog', () async {
    final dir = await Directory.systemTemp.createTemp('integrated_sync_');
    final provider = _Sync();
    final controller = AppController(
      tokenStorage: _Tokens(),
      syncProvider: provider,
      imageRootPathOverride: '${dir.path}/images',
    );
    try {
      await controller.openDatabase('${dir.path}/catalog.db', remember: false);
      await controller.database.saveRecord(
        CatalogRecord(work: BookWork(title: 'Original')),
      );
      final bundle = '${dir.path}/original.realmwise';
      await controller.exportDeviceBundle(bundle);
      final identity = await controller.database.ensureCatalogIdentity();
      await controller.syncCoordinator.connect(provider, identity);
      controller.syncCoordinator.metadata = controller.syncCoordinator.metadata!
          .copyWith(
            revision: 'r1',
            contentHash: 'h1',
            lastSuccessfulLocalFingerprint: 'previous',
          );
      final sync = controller.syncNow();
      await provider.started.future;
      var restored = false;
      final restore = controller
          .restoreDeviceBundle(bundle)
          .then((_) => restored = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.database.isOpen, isTrue);
      expect(restored, isFalse);
      provider.release.complete();
      await sync;
      await restore;
      expect(controller.database.isOpen, isTrue);
      expect(
        (await controller.database.listRecords()).single.work.title,
        'Original',
      );
    } finally {
      if (!provider.release.isCompleted) provider.release.complete();
      await controller.closeDatabase();
      controller.dispose();
      await dir.delete(recursive: true);
    }
  });
}
