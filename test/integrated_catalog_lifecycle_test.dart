import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:realmwise/services/catalog_recovery.dart';
import 'package:realmwise/services/catalog_service.dart';
import 'package:realmwise/services/diagnostic_logging.dart';
import 'package:realmwise/services/image_storage_service.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/sync/sync_session.dart';

class _Tokens implements TokenStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _HeldImages extends ImageStorageService {
  _HeldImages() : super(null);
  final published = Completer<void>();
  final release = Completer<void>();

  @override
  Future<BookImage> publishStagedImage(BookImage image, BookWork work) async {
    final result = await super.publishStagedImage(image, work);
    published.complete();
    await release.future;
    return result;
  }
}

class _HeldImageController extends AppController {
  _HeldImageController(String imageRoot)
    : super(tokenStorage: _Tokens(), imageRootPathOverride: imageRoot);

  final heldImages = _HeldImages();

  @override
  ImageStorageService get imageStorage => heldImages;
}

class _FetchedImageController extends AppController {
  _FetchedImageController(String imageRoot, {super.syncProvider})
    : super(tokenStorage: _Tokens(), imageRootPathOverride: imageRoot);

  int fetches = 0;

  @override
  ImageStorageService get imageStorage => _fetchedImages;

  late final _FetchedImages _fetchedImages = _FetchedImages(
    transport: (uri, peer) async {
      fetches++;
      return http.StreamedResponse(
        Stream<List<int>>.value(const [
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
          0,
          0,
          0,
          0,
        ]),
        200,
        headers: const {'content-type': 'image/png'},
      );
    },
  );
}

class _FetchedImages extends ImageStorageService {
  _FetchedImages({required ImageSecureTransport transport})
    : super(
        null,
        resolver: (_) async => [InternetAddress('93.184.216.34')],
        transport: transport,
      );

  String? failPublishTitle;

  @override
  Future<BookImage> publishStagedImage(BookImage image, BookWork work) {
    if (work.title == failPublishTitle) {
      throw const FileSystemException('injected cover publish failure');
    }
    return super.publishStagedImage(image, work);
  }
}

class _Sync extends Object implements SyncProvider {
  Uint8List? downloadPayload;
  int downloads = 0;
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
  }) async {
    downloads++;
    return SyncDownloadResult(
      payload: downloadPayload!,
      metadata: (await metadata(session, target))!,
    );
  }
}

class _DiagnosticCapture extends DiagnosticLogger {
  final failures = <(String, Map<String, Object?>)>[];

  @override
  Future<void> log(
    DiagnosticSeverity severity,
    String event, [
    Map<String, Object?> fields = const {},
  ]) async {
    if (event.endsWith('.error')) failures.add((event, fields));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => Directory.systemTemp.path,
      );

  test('bundle import commits when a remote cover is fetched', () async {
    final dir = await Directory.systemTemp.createTemp('fetched_cover_import_');
    final controller = _FetchedImageController('${dir.path}/images');
    try {
      await controller.openDatabase('${dir.path}/catalog.db', remember: false);
      await controller.database.saveRecord(
        const CatalogRecord(
          work: BookWork(title: 'Cloud work'),
          images: [
            BookImage(
              localPath: '',
              remoteUrl: 'https://example.com/cover.png',
              sourceType: ImageSourceType.remoteCache,
              isCover: true,
            ),
          ],
        ),
      );
      final bundle = '${dir.path}/cloud.realmwise';
      await controller.exportDeviceBundle(bundle);

      final result = await controller.restoreDeviceBundle(bundle);

      expect(result.needsAcknowledgement, isFalse);
      expect(controller.fetches, greaterThan(0));
      final restored = (await controller.database.listRecords()).single;
      expect(restored.work.title, 'Cloud work');
      expect(restored.cover!.localPath, isNotEmpty);
      expect(await File(restored.cover!.localPath).exists(), isTrue);
    } finally {
      await controller.closeDatabase();
      controller.dispose();
      await dir.delete(recursive: true);
    }
  });

  for (final cloudDownload in [false, true]) {
    test(
      '${cloudDownload ? 'cloud download' : 'bundle import'} commits despite a failed cover publish and rehydrates the next work',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'failed_cover_import_',
        );
        final provider = _Sync();
        final previousLogger = DiagnosticDiagnostics.logger;
        final controller = _FetchedImageController(
          '${dir.path}/images',
          syncProvider: provider,
        );
        addTearDown(() => DiagnosticDiagnostics.logger = previousLogger);
        try {
          await controller.openDatabase(
            '${dir.path}/catalog.db',
            remember: false,
          );
          for (final title in ['A failed cover', 'B restored cover']) {
            await controller.database.saveRecord(
              CatalogRecord(
                work: BookWork(title: title),
                images: [
                  BookImage(
                    localPath: '',
                    remoteUrl: 'https://example.com/cover.png',
                    caption: 'Retained caption',
                    sourceType: ImageSourceType.remoteCache,
                    isCover: true,
                  ),
                ],
              ),
            );
          }
          final bundle = '${dir.path}/incoming.realmwise';
          await controller.exportDeviceBundle(bundle);
          provider.downloadPayload = await File(bundle).readAsBytes();
          // Distinguish the replacement from the original that would be rolled back.
          for (final record in await controller.database.listRecords()) {
            await controller.database.deleteRecord(record.work.id!);
          }
          await controller.database.saveRecord(
            const CatalogRecord(work: BookWork(title: 'Original catalog')),
          );
          controller._fetchedImages.failPublishTitle = 'A failed cover';
          final capture = _DiagnosticCapture();
          DiagnosticDiagnostics.logger = capture;

          if (cloudDownload) {
            final identity = await controller.database.ensureCatalogIdentity();
            await controller.syncCoordinator.connect(provider, identity);
            final decision = await controller.downloadCatalog() as SyncDecision;
            final result = await controller.answerSyncDecision(
              decision,
              SyncChoice.download,
            );
            expect(
              result,
              isA<SyncDownloaded>().having(
                (result) => result.needsRecoveryReview,
                'needs recovery review',
                isFalse,
              ),
            );
            expect(provider.downloads, 1);
          } else {
            final result = await controller.restoreDeviceBundle(bundle);

            expect(result.needsAcknowledgement, isFalse);
          }
          expect(controller.recoveryWarning, isNull);
          final restored = await controller.database.listRecords();
          expect(restored.map((record) => record.work.title), [
            'A failed cover',
            'B restored cover',
          ]);
          expect(restored.first.cover!.localPath, isEmpty);
          expect(restored.first.cover!.caption, 'Retained caption');
          expect(
            restored.first.cover!.remoteUrl,
            'https://example.com/cover.png',
          );
          expect(await File(restored.last.cover!.localPath).exists(), isTrue);
          expect(controller.fetches, 2);
          expect(capture.failures, hasLength(1));
          expect(capture.failures.single.$1, 'catalog.save.error');
          expect(capture.failures.single.$2, {
            'operation': 'save',
            'outcome': 'failed',
            'errorClass': 'FileSystemException',
          });
        } finally {
          await controller.closeDatabase();
          controller.dispose();
          await dir.delete(recursive: true);
        }
      },
    );
  }

  for (final refusal in ['busy checkpoint', 'failed snapshot']) {
    test(
      'replacement refused by $refusal preserves usable staged edits',
      () async {
        final dir = await Directory.systemTemp.createTemp('refused_import_');
        final controller = AppController(
          tokenStorage: _Tokens(),
          imageRootPathOverride: '${dir.path}/images',
        );
        Database? reader;
        final backups = Directory('${dir.path}/backups');
        final parkedBackups = Directory('${dir.path}/protected-backups');
        try {
          await controller.openDatabase(
            '${dir.path}/catalog.db',
            remember: false,
          );
          final original = await controller.database.saveRecord(
            CatalogRecord(work: BookWork(title: 'Original')),
          );
          final bundle = '${dir.path}/original.realmwise';
          await controller.exportDeviceBundle(bundle);
          final source = File('${dir.path}/cover.jpg');
          await source.writeAsBytes([1, 2, 3]);
          final edit = controller.catalog.beginEditing(original);
          edit.update(
            original.copyWith(
              work: original.work.copyWith(title: 'Unsaved title'),
            ),
          );
          await edit.addFile(source.path, label: 'Unsaved cover');
          final staged = edit.record.images.single.localPath;
          final originalHandle = controller.database.databaseHandle;

          if (refusal == 'busy checkpoint') {
            await originalHandle.rawQuery('PRAGMA journal_mode=WAL');
            await originalHandle.execute('PRAGMA busy_timeout=0');
            await originalHandle.insert('works', {
              'title': 'Committed WAL row',
            });
            reader = await databaseFactory.openDatabase(
              controller.database.databasePath,
              options: OpenDatabaseOptions(singleInstance: false),
            );
            await reader.execute('BEGIN');
            await reader.rawQuery('SELECT * FROM works');
            expect(
              (await originalHandle.rawQuery('PRAGMA wal_checkpoint(FULL)'))
                  .single['busy'],
              0,
            );
          } else {
            // A filesystem failure at snapshot creation must leave the editor intact.
            await backups.rename(parkedBackups.path);
            await File(backups.path)
                .writeAsString('Snapshot destination unavailable');
          }
          try {
            await expectLater(
              controller.restoreDeviceBundle(bundle),
              refusal == 'busy checkpoint'
                  ? throwsA(
                      isA<StateError>().having(
                        (error) => error.message,
                        'message',
                        contains('catalog is busy'),
                      ),
                    )
                  : throwsA(isA<FileSystemException>()),
            );
            if (refusal == 'busy checkpoint') {
              expect(
                (await controller.recovery.restorePoints()).any(
                  (point) => point.kind == SnapshotKind.preImport,
                ),
                isTrue,
              );
            }
            expect(controller.database.databaseHandle, same(originalHandle));
            expect(await File(staged).readAsBytes(), [1, 2, 3]);
            expect(
              (await controller.database.getRecord(original.work.id!))
                  .work
                  .title,
              'Original',
            );
          } finally {
            if (reader != null) {
              await reader.execute('ROLLBACK');
              await reader.close();
              reader = null;
            }
            if (await parkedBackups.exists()) {
              await File(backups.path).delete();
              await parkedBackups.rename(backups.path);
            }
          }

          final saved = await edit.save();
          expect(saved.work.title, 'Unsaved title');
          final reopened = await controller.database.getRecord(saved.work.id!);
          expect(reopened.work.title, 'Unsaved title');
          expect(await File(reopened.images.single.localPath).readAsBytes(), [
            1,
            2,
            3,
          ]);
        } finally {
          if (reader != null) {
            await reader.execute('ROLLBACK');
            await reader.close();
          }
          await controller.closeDatabase();
          controller.dispose();
          await dir.delete(recursive: true);
        }
      },
    );
  }

  test(
    'protective snapshot includes a save already publishing images',
    () async {
      final dir = await Directory.systemTemp.createTemp('held_save_snapshot_');
      final controller = AppController(
        tokenStorage: _Tokens(),
        imageRootPathOverride: '${dir.path}/images',
      );
      CatalogRecovery? recovery;
      try {
        await controller.openDatabase(
          '${dir.path}/catalog.db',
          remember: false,
        );
        final original = await controller.database.saveRecord(
          CatalogRecord(work: BookWork(title: 'Original')),
        );
        final bundle = '${dir.path}/original.realmwise';
        await controller.exportDeviceBundle(bundle);
        final source = File('${dir.path}/cover.jpg');
        await source.writeAsBytes([1, 2, 3]);
        final images = _HeldImages();
        await images.initialize('${dir.path}/images');
        final catalog = CatalogService(
          database: controller.database,
          images: images,
        );
        final edit = catalog.beginEditing(original);
        edit.update(
          original.copyWith(work: original.work.copyWith(title: 'Saved title')),
        );
        await edit.addFile(source.path, label: 'New cover');
        final lateEdit = catalog.beginEditing(original);
        final saving = edit.save();
        await images.published.future;
        recovery = CatalogRecovery(
          database: controller.database,
          freezeEdits: catalog.freezeEdits,
          releaseEdits: () async => catalog.unfreezeEdits(),
          beforeClose: () async {
            await expectLater(
              lateEdit.save(),
              throwsA(isA<CatalogEditPausedException>()),
            );
            await catalog.discardEdits();
          },
        );
        final replacing = recovery.replaceCatalog(bundle, bundle: true);
        await Future<void>.delayed(Duration.zero);
        expect(
          (await recovery.restorePoints()).where(
            (point) => point.kind == SnapshotKind.preImport,
          ),
          isEmpty,
        );
        images.release.complete();
        expect((await saving).work.title, 'Saved title');
        await replacing;
        final point = (await recovery.restorePoints()).singleWhere(
          (point) => point.kind == SnapshotKind.preImport,
        );
        final snapshot = DatabaseService();
        try {
          await snapshot.open(point.path);
          expect(
            (await snapshot.listRecords()).single.work.title,
            'Saved title',
          );
        } finally {
          await snapshot.close();
        }
      } finally {
        await recovery?.stop();
        await controller.closeDatabase();
        controller.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'controller replacement waits for a held save before snapshot',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'controller_held_save_',
      );
      final controller = _HeldImageController('${dir.path}/images');
      try {
        await controller.openDatabase(
          '${dir.path}/catalog.db',
          remember: false,
        );
        final original = await controller.database.saveRecord(
          CatalogRecord(work: BookWork(title: 'Original')),
        );
        final bundle = '${dir.path}/original.realmwise';
        await controller.exportDeviceBundle(bundle);
        final cover = File('${dir.path}/cover.jpg');
        await cover.writeAsBytes([1, 2, 3]);
        final edit = controller.catalog.beginEditing(original);
        edit.update(
          original.copyWith(work: original.work.copyWith(title: 'Saved title')),
        );
        await edit.addFile(cover.path, label: 'New cover');
        final saving = edit.save();
        await controller.heldImages.published.future;
        final replacing = controller.restoreDeviceBundle(bundle);
        await Future<void>.delayed(Duration.zero);
        expect(
          (await controller.recovery.restorePoints()).where(
            (point) => point.kind == SnapshotKind.preImport,
          ),
          isEmpty,
        );
        controller.heldImages.release.complete();
        await saving;
        await replacing;
        final point = (await controller.recovery.restorePoints()).singleWhere(
          (point) => point.kind == SnapshotKind.preImport,
        );
        final snapshot = DatabaseService();
        try {
          await snapshot.open(point.path);
          expect(
            (await snapshot.listRecords()).single.work.title,
            'Saved title',
          );
        } finally {
          await snapshot.close();
        }
      } finally {
        if (!controller.heldImages.release.isCompleted) {
          controller.heldImages.release.complete();
        }
        await controller.closeDatabase();
        controller.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test('marker write refusal unfreezes staged edits', () async {
    final dir = await Directory.systemTemp.createTemp('marker_refusal_');
    final database = DatabaseService();
    CatalogRecovery? recovery;
    try {
      final active = '${dir.path}/catalog.db';
      await database.open(active);
      final original = await database.saveRecord(
        CatalogRecord(work: BookWork(title: 'Original')),
      );
      final source = '${dir.path}/replacement.db';
      await File(active).copy(source);
      final images = ImageStorageService(null);
      await images.initialize('${dir.path}/images');
      final catalog = CatalogService(database: database, images: images);
      final cover = File('${dir.path}/cover.jpg');
      await cover.writeAsBytes([1, 2, 3]);
      final edit = catalog.beginEditing(original);
      await edit.addFile(cover.path, label: 'Staged cover');
      final staged = edit.record.images.single.localPath;
      recovery = CatalogRecovery(
        database: database,
        freezeEdits: catalog.freezeEdits,
        releaseEdits: () async => catalog.unfreezeEdits(),
        beforeClose: catalog.discardEdits,
        renameFile: (file, target) async {
          if (file.path.contains('.recovery-review.json.write-')) {
            throw const FileSystemException('marker write blocked');
          }
          return file.rename(target);
        },
      );
      await expectLater(
        recovery.replaceCatalog(source),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(staged).readAsBytes(), [1, 2, 3]);
      final saved = await edit.save();
      expect(saved.images, hasLength(1));
      expect((await database.listRecords()).single.images, hasLength(1));
    } finally {
      await recovery?.stop();
      await database.close();
      await dir.delete(recursive: true);
    }
  });

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
      final sync = controller.syncCatalog();
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
