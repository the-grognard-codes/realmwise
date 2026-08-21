import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rpg_catalog/data/database_service.dart';
import 'package:rpg_catalog/models/catalog_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SQLite saves, updates, filters suggestions, and deletes a complete record',
    () async {
      final folder = await Directory.systemTemp.createTemp('rpg_catalog_test_');
      final service = DatabaseService();
      await service.open('${folder.path}${Platform.pathSeparator}catalog.db');

      final saved = await service.saveRecord(
        const CatalogRecord(
          work: BookWork(
            title: 'The Grand Grimoire',
            isbn13: '9781234567890',
            gameSystem: 'Arcana',
            gameSetting: 'Old Realm',
            bookType: 'Sourcebook',
          ),
          copies: [
            UserCopy(
              acquiredSource: 'Friendly Local Game Store',
              tags: ['magic', 'reference'],
            ),
          ],
        ),
      );
      expect(saved.work.id, isNotNull);
      expect(
        (await service.listRecords()).single.work.title,
        'The Grand Grimoire',
      );
      expect(await service.suggestions('game_system', 'arc'), ['Arcana']);
      expect(await service.allTags(), ['magic', 'reference']);

      final changed = await service.saveRecord(
        saved.copyWith(
          work: saved.work.copyWith(title: 'The Greater Grimoire'),
        ),
      );
      expect(changed.work.title, 'The Greater Grimoire');
      await service.deleteRecord(changed.work.id!);
      expect(await service.listRecords(), isEmpty);

      await service.close();
      await folder.delete(recursive: true);
    },
  );

  test('catalog icon mappings round trip and v1 databases migrate', () async {
    final folder = await Directory.systemTemp.createTemp('rpg_catalog_icons_');
    final dbPath = '${folder.path}${Platform.pathSeparator}catalog.db';
    final service = DatabaseService();
    await service.open(dbPath);
    await service.upsertCatalogIcon(const CatalogIconMapping(tier: 'gameSystem', sectionName: 'Arcana', localPath: '/tmp/icon.png', alignmentX: .2, alignmentY: -.4, zoom: 2.25));
    final loaded = await service.getCatalogIcon('gameSystem', 'Arcana');
    expect(loaded?.localPath, '/tmp/icon.png');
    expect(loaded?.zoom, 2.25);
    expect((await service.listCatalogIcons()).length, 1);
    await service.removeCatalogIcon('gameSystem', 'Arcana');
    expect(await service.listCatalogIcons(), isEmpty);
    await service.close();
    final v2Path = '${folder.path}${Platform.pathSeparator}v2.db';
    final v2 = await openDatabase(v2Path, version: 2, onCreate: (db, _) async => db.execute('CREATE TABLE catalog_icons (tier TEXT NOT NULL, section_name TEXT NOT NULL, local_path TEXT NOT NULL, alignment_x REAL NOT NULL DEFAULT 0, alignment_y REAL NOT NULL DEFAULT 0, PRIMARY KEY (tier, section_name))'));
    await v2.insert('catalog_icons', {'tier': 'gameSystem', 'section_name': 'Legacy', 'local_path': '/tmp/legacy.png'});
    await v2.close();
    await service.open(v2Path);
    final migrated = await service.getCatalogIcon('gameSystem', 'Legacy');
    expect(migrated?.zoom, 1);
    await service.close();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final oldPath = '${folder.path}${Platform.pathSeparator}old.db';
    final old = await openDatabase(oldPath, version: 1, onCreate: (db, _) async => db.execute('CREATE TABLE settings (setting_key TEXT PRIMARY KEY, setting_value TEXT NOT NULL)'));
    await old.close();
    await service.open(oldPath);
    expect(await service.listCatalogIcons(), isEmpty);
    await service.close();
    await folder.delete(recursive: true);
  });

  test('extended RPGGeek metadata persists in the works table', () async {
    final folder = await Directory.systemTemp.createTemp('rpg_catalog_metadata_');
    final service = DatabaseService();
    await service.open('${folder.path}${Platform.pathSeparator}catalog.db');
    final saved = await service.saveRecord(const CatalogRecord(
      work: BookWork(
        title: 'Metadata Manual',
        moreInfo: 'Expanded details',
        designers: ['A Designer'],
        artists: ['An Artist'],
        productionStaff: ['Editor'],
        version: '2nd edition',
        productCode: 'PR-42',
        seriesCode: 'SER-7',
        dimensions: '8 x 11 in',
        series: ['Core line'],
        setting: ['The Realm'],
        family: ['Fantasy'],
        system: ['d20'],
        category: ['Sourcebook'],
        mechanics: ['Dice rolling'],
        genre: ['High fantasy'],
      ),
    ));
    final loaded = await service.getRecord(saved.work.id!);
    expect(loaded.work.moreInfo, 'Expanded details');
    expect(loaded.work.designers, ['A Designer']);
    expect(loaded.work.productionStaff, ['Editor']);
    expect(loaded.work.genre, ['High fantasy']);
    await service.close();
    await folder.delete(recursive: true);
  });

  test('product code survives editing and saving an existing record', () async {
    final folder = await Directory.systemTemp.createTemp('rpg_catalog_product_code_');
    final service = DatabaseService();
    await service.open('${folder.path}${Platform.pathSeparator}catalog.db');

    final saved = await service.saveRecord(
      const CatalogRecord(
        work: BookWork(title: 'Product Code Manual', productCode: 'OLD-1'),
      ),
    );
    final edited = await service.saveRecord(
      saved.copyWith(work: saved.work.copyWith(productCode: 'NEW-2')),
    );

    expect(edited.work.productCode, 'NEW-2');
    expect((await service.getRecord(saved.work.id!)).work.productCode, 'NEW-2');

    await service.close();
    await folder.delete(recursive: true);
  });
}
