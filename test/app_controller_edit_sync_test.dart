import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/app_controller.dart';
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
  late Directory folder;
  late AppController controller;
  late CatalogRecord original;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    folder = await Directory.systemTemp.createTemp('edited_sync_');
    controller = AppController(
      tokenStorage: _Tokens(),
      imageRootPathOverride: '${folder.path}/images',
    );
    await controller.openDatabase('${folder.path}/catalog.db', remember: false);
    final first = File('${controller.imageStorage.rootPath}/first_cover.jpg');
    final second = File('${controller.imageStorage.rootPath}/second.jpg');
    await first.writeAsBytes([1, 2, 3]);
    await second.writeAsBytes([4, 5, 6]);
    original = await controller.database.saveRecord(
      CatalogRecord(
        work: BookWork(title: 'Original'),
        images: [
          BookImage(localPath: first.path, isCover: true),
          BookImage(localPath: second.path),
        ],
      ),
    );
  });
  tearDown(() async {
    await controller.closeDatabase();
    controller.dispose();
    await folder.delete(recursive: true);
  });

  test('sync upload after a cover edit contains the committed rows and image bytes', () async {
    final provider = _Provider();
    final identity = await controller.database.ensureCatalogIdentity();
    await controller.syncCoordinator.connect(provider, identity);
    controller.syncCoordinator.metadata = SyncMetadata(
      catalogIdentity: identity,
      provider: 'fake',
      accountId: 'account',
      remoteTargetId: 'target',
      revision: 'r1',
      contentHash: 'h1',
      lastSuccessfulLocalFingerprint: 'baseline',
      state: SyncState.ready,
    );
    await controller.setIncludePersonalImagesInBundles(true);
    final edit = controller.catalog.beginEditing(original)..setCover(1);
    final saved = await edit.save();
    await controller.syncCatalog();
    final uploaded = File('${folder.path}/uploaded.realmwise');
    await uploaded.writeAsBytes(provider.payload!);
    final manifest = await controller.bundles.validateBundle(uploaded.path);
    expect(manifest.assets, hasLength(2));
    final extracted = DatabaseService();
    await controller.bundles.extractDatabase(
      uploaded.path,
      '${folder.path}/uploaded.db',
      imageRootPath: '${folder.path}/uploaded-images',
    );
    await extracted.open('${folder.path}/uploaded.db');
    try {
      final record = await extracted.getRecord(saved.work.id!);
      expect(record.images.where((image) => image.isCover), hasLength(1));
      expect(await File(record.cover!.localPath).readAsBytes(), [4, 5, 6]);
      expect(await File(record.images.first.localPath).readAsBytes(), [
        1,
        2,
        3,
      ]);
    } finally {
      await extracted.close();
    }
  });

  test('disconnect preserves staged edits while close discards them', () async {
    final edit = controller.catalog.beginEditing(original);
    await edit.addFile(original.images.last.localPath, label: 'added');
    final staged = edit.record.images.last.localPath;
    await controller.disconnectGoogleDrive();
    expect(await File(staged).exists(), isTrue);
    final saved = await edit.save();
    expect(saved.images, hasLength(3));
    final closingEdit = controller.catalog.beginEditing(saved);
    await closingEdit.addFile(saved.images.last.localPath, label: 'discarded');
    final discarded = closingEdit.record.images.last.localPath;
    await controller.closeDatabase();
    expect(await File(discarded).exists(), isFalse);
    await expectLater(closingEdit.save(), throwsStateError);
  });
}

class _Provider implements SyncProvider {
  Uint8List? payload;
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
    this.payload = payload;
    return const SyncUploadResult(
      metadata: SyncRemoteMetadata(
        revision: SyncRevision('r2'),
        contentHash: 'h2',
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

class _Tokens implements TokenStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}
