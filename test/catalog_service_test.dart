import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/catalog_service.dart';
import 'package:realmwise/services/image_storage_service.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:realmwise/services/catalog_bundle_service.dart';
import 'package:realmwise/services/diagnostic_logging.dart';

class _FakeImages extends ImageStorageService {
  _FakeImages(this.folder, {this.fail = false}) : super(null);
  final Directory folder;
  final bool fail;
  int downloads = 0;

  @override
  String get rootPath => folder.path;

  @override
  Future<BookImage> stageRemoteCover({
    required Directory directory,
    required BookWork work,
    required String remoteUrl,
  }) async {
    downloads++;
    if (fail) throw const FormatException('offline');
    final file = File('${directory.path}/download_$downloads.jpg');
    await file.writeAsBytes([1, 2, 3]);
    return BookImage(
      localPath: file.path,
      remoteUrl: remoteUrl,
      sourceType: ImageSourceType.remoteCache,
    );
  }
}

void main() {
  group('edit sessions', _editSessionTests);
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rehydrates missing remote images and retains local-only images',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'realmwise_catalog_',
      );
      final database = DatabaseService();
      await database.open('${folder.path}/catalog.db');
      final localOnly = '${folder.path}/missing-local.jpg';
      final saved = await database.saveRecord(
        CatalogRecord(
          work: BookWork(
            title: 'Book',
            remoteCoverUrl: 'https://example.com/work.jpg',
          ),
          images: [
            BookImage(
              localPath: '',
              remoteUrl: 'https://example.com/image.jpg',
              caption: 'Keep me',
              isCover: true,
              sourceType: ImageSourceType.remoteCache,
            ),
            BookImage(
              localPath: localOnly,
              caption: 'User image',
              isCover: true,
            ),
          ],
        ),
      );
      final fake = _FakeImages(folder);
      final changed = await CatalogService(
        database: database,
        images: fake,
      ).rehydrateMissingImages();
      expect(changed, isTrue);
      expect(fake.downloads, 1);
      final loaded = await database.getRecord(saved.work.id!);
      expect(loaded.images[0].localPath, isNotEmpty);
      expect(loaded.images[0].remoteUrl, 'https://example.com/image.jpg');
      expect(loaded.images[0].caption, 'Keep me');
      expect(loaded.images[0].isCover, isTrue);
      expect(loaded.images[1].localPath, localOnly);
      await database.close();
      await folder.delete(recursive: true);
    },
  );

  test(
    'download failures are tolerated and preserve missing image metadata',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'realmwise_catalog_fail_',
      );
      final database = DatabaseService();
      await database.open('${folder.path}/catalog.db');
      final saved = await database.saveRecord(
        const CatalogRecord(
          work: BookWork(title: 'Book'),
          images: [
            BookImage(
              localPath: '',
              remoteUrl: 'https://example.com/image.jpg',
              caption: 'Keep',
              sourceType: ImageSourceType.remoteCache,
            ),
          ],
        ),
      );
      final fake = _FakeImages(folder, fail: true);
      final changed = await CatalogService(
        database: database,
        images: fake,
      ).rehydrateMissingImages();
      expect(changed, isFalse);
      final loaded = await database.getRecord(saved.work.id!);
      expect(loaded.images.single.localPath, isEmpty);
      expect(loaded.images.single.caption, 'Keep');
      await database.close();
      await folder.delete(recursive: true);
    },
  );
}

class _BlockingImages extends ImageStorageService {
  _BlockingImages() : super(null);
  String? hydrationSource;
  @override
  Future<BookImage> stageRemoteCover({
    required Directory directory,
    required BookWork work,
    required String remoteUrl,
  }) async {
    if (hydrationSource == null)
      return super.stageRemoteCover(
        directory: directory,
        work: work,
        remoteUrl: remoteUrl,
      );
    final image = await stageFile(
      directory: directory,
      work: work,
      sourcePath: hydrationSource!,
      label: 'remote',
      cover: true,
    );
    return image.copyWith(
      remoteUrl: remoteUrl,
      sourceType: ImageSourceType.remoteCache,
    );
  }

  bool block = false, failRollback = false;
  int rollbackAttempts = 0;
  final rolledBack = <String>[];
  @override
  Future<void> rollbackPublishedImage(String published, String staged) async {
    rollbackAttempts++;
    if (failRollback && rollbackAttempts == 1)
      throw const FileSystemException('injected rollback failure');
    await super.rollbackPublishedImage(published, staged);
    rolledBack.add(staged);
  }

  final published = Completer<void>(), release = Completer<void>();
  @override
  Future<BookImage> publishStagedImage(BookImage image, BookWork work) async {
    final result = await super.publishStagedImage(image, work);
    if (block && !published.isCompleted) {
      published.complete();
      await release.future;
    }
    return result;
  }
}

void _editSessionTests() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => Directory.systemTemp.path,
      );
  late Directory dir;
  late DatabaseService database;
  late _BlockingImages images;
  late CatalogService catalog;
  late CatalogRecord original;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalog_edit_');
    database = DatabaseService();
    await database.open(p.join(dir.path, 'catalog.db'));
    images = _BlockingImages();
    await images.initialize(p.join(dir.path, 'images'));
    final first = File(p.join(images.rootPath, 'first_cover.jpg'));
    final second = File(p.join(images.rootPath, 'second.jpg'));
    await first.writeAsBytes([1, 2, 3]);
    await second.writeAsBytes([4, 5, 6]);
    original = await database.saveRecord(
      CatalogRecord(
        work: BookWork(title: 'Original'),
        copies: [UserCopy(notes: 'Owned copy')],
        images: [
          BookImage(localPath: first.path, caption: 'first', isCover: true),
          BookImage(localPath: second.path, caption: 'second'),
        ],
      ),
    );
    catalog = CatalogService(database: database, images: images);
  });
  tearDown(() async {
    await catalog.discardEdits();
    await database.close();
    await dir.delete(recursive: true);
  });

  Future<void> expectOriginal() async {
    final saved = await database.getRecord(original.work.id!);
    expect(
      saved.images.map((image) => image.toRow(original.work.id!)),
      original.images.map((image) => image.toRow(original.work.id!)),
    );
    expect(await File(original.images[0].localPath).readAsBytes(), [1, 2, 3]);
    expect(await File(original.images[1].localPath).readAsBytes(), [4, 5, 6]);
  }

  for (final operation in ['cover', 'remove', 'add']) {
    test(
      '$operation then discard preserves rows and original image bytes',
      () async {
        final edit = catalog.beginEditing(original);
        switch (operation) {
          case 'cover':
            edit.setCover(1);
          case 'remove':
            edit.removeImage(0);
          case 'add':
            await edit.addFile(original.images[1].localPath, label: 'new');
        }
        await edit.discard();
        await expectOriginal();
        expect(
          Directory(images.rootPath)
              .listSync(recursive: true)
              .whereType<File>(),
          hasLength(2),
        );
      },
    );
  }

  test(
    'cover save publishes consistent names, rows and image contents',
    () async {
      final edit = catalog.beginEditing(original)..setCover(1);
      final saved = await edit.save();
      expect(saved.cover!.caption, 'second');
      expect(p.basename(saved.cover!.localPath), contains('_cover.'));
      expect(await File(saved.cover!.localPath).readAsBytes(), [4, 5, 6]);
      expect(saved.images.where((image) => image.isCover), hasLength(1));
      for (final image in original.images) {
        expect(await File(image.localPath).exists(), isFalse);
      }
      final rows = await database.getRecord(saved.work.id!);
      expect(
        rows.images.map((image) => image.localPath),
        saved.images.map((image) => image.localPath),
      );
    },
  );

  test(
    'discard during save waits for commit and preserves the requested edit',
    () async {
      images.block = true;
      final edit = catalog.beginEditing(original)..setCover(1);
      final saving = edit.save();
      await images.published.future;
      final discarding = edit.discard();
      images.release.complete();
      final saved = await saving;
      await discarding;
      expect(
        (await database.getRecord(saved.work.id!)).cover!.caption,
        'second',
      );
      expect(await File(saved.cover!.localPath).readAsBytes(), [4, 5, 6]);
    },
  );

  test(
    'rollback continues after a rename error and preserves the database error',
    () async {
      images.failRollback = true;
      final edit = catalog.beginEditing(original)..setCover(1);
      await edit.addFile(original.images.first.localPath, label: 'added');
      await database.databaseHandle.execute(
        "CREATE TRIGGER reject_images BEFORE INSERT ON images BEGIN SELECT RAISE(ABORT, 'primary transaction failure'); END",
      );
      await expectLater(
        edit.save(),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('primary transaction failure'),
          ),
        ),
      );
      expect(images.rollbackAttempts, 3);
      expect(images.rolledBack, hasLength(2));
      for (final file in images.rolledBack) {
        expect(await File(file).exists(), isTrue);
      }
      await expectOriginal();
    },
  );

  test(
    'delete waits for an export and retains another work image reference',
    () async {
      final shared = await database.saveRecord(
        CatalogRecord(
          work: BookWork(title: 'Shared'),
          images: [original.images.first],
        ),
      );
      final entered = Completer<void>(), release = Completer<void>();
      final reading = database.withCatalogFiles(() async {
        entered.complete();
        await release.future;
        expect(await File(original.images.first.localPath).exists(), isTrue);
        expect(
          (await database.getRecord(original.work.id!)).images,
          hasLength(2),
        );
      });
      await entered.future;
      var deleted = false;
      final deleting = catalog.delete(original).then((_) => deleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(deleted, isFalse);
      release.complete();
      await reading;
      await deleting;
      expect(await File(original.images.first.localPath).exists(), isTrue);
      expect(await File(original.images.last.localPath).exists(), isFalse);
      expect((await database.getRecord(shared.work.id!)).images, hasLength(1));
    },
  );

  test(
    'rehydration publishes under the export lock with committed image bytes',
    () async {
      images.hydrationSource = original.images.last.localPath;
      images.block = true;
      final missing = await database.saveRecord(
        const CatalogRecord(
          work: BookWork(title: 'Rehydrated'),
          images: [
            BookImage(
              localPath: '',
              remoteUrl: 'https://example.com/cover.jpg',
              sourceType: ImageSourceType.remoteCache,
              isCover: true,
            ),
          ],
        ),
      );
      final hydrating = catalog.rehydrateMissingImages();
      await images.published.future;
      var exported = false;
      final bundles = CatalogBundleService();
      final bundle = p.join(dir.path, 'rehydrated.realmwise');
      final exporting = bundles
          .exportBundle(
            database: database,
            outputPath: bundle,
            includePersonalImages: true,
          )
          .then((_) => exported = true);
      await Future<void>.delayed(Duration.zero);
      expect(exported, isFalse);
      images.release.complete();
      expect(await hydrating, isTrue);
      await exporting;
      final loaded = await database.getRecord(missing.work.id!);
      expect(await File(loaded.cover!.localPath).readAsBytes(), [4, 5, 6]);
      // Downloadable remote caches are omitted by the portable-bundle policy.
      expect((await bundles.validateBundle(bundle)).assets, hasLength(2));
    },
  );

  test('cover fetch does not block export; closing its catalog emits save diagnostics', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final capture = _DiagnosticCapture();
    final previousLogger = DiagnosticDiagnostics.logger;
    DiagnosticDiagnostics.logger = capture;
    addTearDown(() => DiagnosticDiagnostics.logger = previousLogger);
    final remoteImages = ImageStorageService(
      null,
      resolver: (_) async => [InternetAddress('93.184.216.34')],
      transport: (_, _) async {
        entered.complete();
        await release.future;
        return http.StreamedResponse(Stream.value([1, 2, 3]), 500);
      },
    );
    await remoteImages.initialize(images.rootPath);
    catalog = CatalogService(database: database, images: remoteImages);
    final edit = catalog.beginEditing(
      const CatalogRecord(
        work: BookWork(
          title: 'Remote',
          remoteCoverUrl: 'https://example.com/cover.png',
        ),
      ),
    );
    final saving = edit.save();
    final failed = expectLater(saving, throwsStateError);
    await entered.future;
    await CatalogBundleService().exportBundle(
      database: database,
      outputPath: p.join(dir.path, 'during-download.realmwise'),
    );
    await database.close();
    release.complete();
    await failed;
    expect(capture.events, contains('catalog.save.error'));
  });

  test('transaction failure restores staged files and leaves originals unchanged; retry works', () async {
    final edit = catalog.beginEditing(original)..setCover(1);
    await edit.addFile(original.images[0].localPath, label: 'added');
    await database.databaseHandle.execute(
      "CREATE TRIGGER reject_images BEFORE INSERT ON images BEGIN SELECT RAISE(ABORT, 'injected transaction failure'); END",
    );
    await expectLater(edit.save(), throwsA(isA<Object>()));
    await expectOriginal();
    expect(await File(edit.record.images.last.localPath).exists(), isTrue);
    expect(
      Directory(images.rootPath).listSync().whereType<File>(),
      hasLength(2),
    );
    await database.databaseHandle.execute('DROP TRIGGER reject_images');
    final saved = await edit.save();
    expect(saved.images, hasLength(3));
    for (final image in saved.images) {
      expect(await File(image.localPath).exists(), isTrue);
    }
  });

  test('removed files are deleted only after save', () async {
    final edit = catalog.beginEditing(original)..removeImage(0);
    expect(await File(original.images[0].localPath).exists(), isTrue);
    final saved = await edit.save();
    expect(await File(original.images[0].localPath).exists(), isFalse);
    expect(saved.images.single.isCover, isTrue);
    expect(await File(saved.images.single.localPath).exists(), isTrue);
  });

  test(
    'downloaded covers stage on request and use the same save path',
    () async {
      var requests = 0;
      final remoteImages = ImageStorageService(
        null,
        resolver: (_) async => [InternetAddress('93.184.216.34')],
        transport: (_, _) async {
          requests++;
          final png = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aSaoAAAAASUVORK5CYII=',
          );
          return http.StreamedResponse(
            Stream.value(png),
            200,
            headers: {'content-type': 'image/png'},
          );
        },
      );
      await remoteImages.initialize(images.rootPath);
      catalog = CatalogService(database: database, images: remoteImages);
      final draft = CatalogRecord(
        work: BookWork(
          title: 'Remote',
          remoteCoverUrl: 'https://example.com/cover.png',
        ),
      );
      final cancelled = catalog.beginEditing(draft);
      expect(requests, 0);
      await cancelled.addRemoteCover();
      final stagedPath = cancelled.record.images.single.localPath;
      expect(stagedPath, contains('.staging'));
      await cancelled.discard();
      expect(await File(stagedPath).exists(), isFalse);
      final saved = await catalog.save(draft);
      expect(requests, 2);
      expect(saved.images.single.sourceType, ImageSourceType.remoteCache);
      expect(saved.images.single.localPath, isNot(contains('.staging')));
      expect(await File(saved.images.single.localPath).exists(), isTrue);
    },
  );

  test(
    'reordering and choosing a cover preserve list order through save',
    () async {
      final edit = catalog.beginEditing(original);
      edit.update(original.copyWith(images: original.images.reversed.toList()));
      edit.setCover(1);
      final saved = await edit.save();
      expect(saved.images.map((image) => image.caption), ['second', 'first']);
      expect(saved.images.map((image) => image.sortOrder), [0, 1]);
      expect(saved.cover!.caption, 'first');
    },
  );

  test(
    'cleanup removes abandoned processes and retains active staged images',
    () async {
      final abandoned = Directory(
        p.join(images.rootPath, '.staging', 'process-1-1'),
      );
      await abandoned.create(recursive: true);
      await File(p.join(abandoned.path, 'orphan.jpg')).writeAsBytes([9]);
      final edit = catalog.beginEditing(original);
      await edit.addFile(original.images[0].localPath, label: 'active');
      await catalog.cleanupAbandonedEdits();
      expect(await abandoned.exists(), isFalse);
      expect(await File(edit.record.images.last.localPath).exists(), isTrue);
      await edit.discard();
      expect(
        Directory(images.rootPath).listSync(recursive: true).whereType<File>(),
        hasLength(2),
      );
    },
  );

  test('session cannot save after catalog replacement or reopening', () async {
    final edit = catalog.beginEditing(original);
    await edit.addFile(original.images[0].localPath, label: 'stale');
    await database.close();
    await database.open(p.join(dir.path, 'different.db'));
    await expectLater(edit.save(), throwsStateError);
    expect(await database.listRecords(), isEmpty);
    await edit.discard();
  });

  test(
    'bundle export waits for image publication and includes committed images',
    () async {
      images.block = true;
      final edit = catalog.beginEditing(original)..setCover(1);
      final save = edit.save();
      await images.published.future;
      var exported = false;
      final bundles = CatalogBundleService();
      final file = p.join(dir.path, 'after-edit.realmwise');
      final export = bundles
          .exportBundle(
            database: database,
            outputPath: file,
            includePersonalImages: true,
          )
          .then((_) => exported = true);
      await Future<void>.delayed(Duration.zero);
      expect(exported, isFalse);
      images.release.complete();
      final saved = await save;
      await export;
      expect(
        (await bundles.validateBundle(file)).assets,
        hasLength(saved.images.length),
      );
    },
  );

  for (final covers in [0, 2]) {
    test('record and bundle import normalize $covers marked covers', () async {
      final record = original.copyWith(
        images: original.images
            .map((image) => image.copyWith(isCover: covers == 2))
            .toList(),
      );
      await database.importRecords([record]);
      final imported = await database.getRecord(original.work.id!);
      expect(imported.images.where((image) => image.isCover), hasLength(1));
      // Simulate a legacy bundle written before normalization was shared.
      await database.databaseHandle.update('images', {
        'is_cover': covers == 2 ? 1 : 0,
      });
      final bundle = p.join(dir.path, 'legacy.realmwise');
      final bundles = CatalogBundleService();
      await bundles.exportBundle(
        database: database,
        outputPath: bundle,
        includePersonalImages: true,
      );
      final extracted = p.join(dir.path, 'extracted.db');
      await bundles.extractDatabase(
        bundle,
        extracted,
        imageRootPath: p.join(dir.path, 'imported-images'),
      );
      final importedDb = DatabaseService();
      await importedDb.open(extracted);
      final result = await importedDb.getRecord(original.work.id!);
      expect(result.images.where((image) => image.isCover), hasLength(1));
      expect(result.images.map((image) => image.sortOrder).toList()..sort(), [
        0,
        1,
      ]);
      await importedDb.close();
    });
  }
}

class _DiagnosticCapture extends DiagnosticLogger {
  final events = <String>[];
  @override
  Future<void> log(
    DiagnosticSeverity severity,
    String event, [
    Map<String, Object?> fields = const {},
  ]) async {
    events.add(event);
  }
}
