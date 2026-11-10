import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/catalog_bundle_service.dart';
import 'package:realmwise/services/catalog_service.dart';
import 'package:realmwise/services/image_storage_service.dart';

class _BlockingImages extends ImageStorageService {
  _BlockingImages() : super(null);
  bool block = false;
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

void main() {
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
      final edit = catalog.beginEditing(original)
        ..reorderImage(0, 1)
        ..setCover(1);
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
