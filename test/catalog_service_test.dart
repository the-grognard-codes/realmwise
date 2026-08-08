import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/catalog_service.dart';
import 'package:realmwise/services/image_storage_service.dart';

class _FakeImages extends ImageStorageService {
  _FakeImages(this.folder, {this.fail = false}) : super(null);
  final Directory folder;
  final bool fail;
  int downloads = 0;

  @override
  Future<BookImage> downloadRemoteCover({
    required BookWork work,
    required String remoteUrl,
  }) async {
    downloads++;
    if (fail) throw const FormatException('offline');
    final file = File('${folder.path}/download_$downloads.jpg');
    await file.writeAsBytes([1, 2, 3]);
    return BookImage(localPath: file.path, remoteUrl: remoteUrl);
  }
}

void main() {
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
