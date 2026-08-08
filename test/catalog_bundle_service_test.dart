import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/services/catalog_bundle_service.dart';
import 'package:realmwise/data/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late CatalogBundleService service;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bundle_test_');
    service = CatalogBundleService();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDown(() => dir.delete(recursive: true));

  Future<String> makeBundle({
    String? manifest,
    List<int>? db,
    String? checksum,
  }) async {
    final database = db ?? (await _sqliteBytes(dir));
    final manifestText =
        manifest ??
        jsonEncode({
          'format_version': 1,
          'app_version': '1.0.0+1',
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'catalog_identity': 'test',
          'database_filename': 'catalog.db',
          'database_sha256': checksum ?? sha256.convert(database).toString(),
        });
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'manifest.json',
          utf8.encode(manifestText).length,
          utf8.encode(manifestText),
        ),
      )
      ..addFile(ArchiveFile('catalog.db', database.length, database));
    final path = '${dir.path}/bundle.zip';
    await File(path).writeAsBytes(ZipEncoder().encode(archive)!);
    return path;
  }

  test('valid bundle validates', () async {
    final result = await service.validateBundle(await makeBundle());
    expect(result.formatVersion, 1);
  });
  test('exports, extracts, and scrubs device data', () async {
    final dbPath = '${dir.path}/catalog.db';
    final database = DatabaseService();
    await database.open(dbPath);
    await database.setSetting('catalog_identity', 'roundtrip');
    await database.setSetting('rpggeek_api_key', 'secret');
    await database.setSetting('image_folder', 'C:/device');
    await database.setSetting('theme_seed', 'Ocean blue');
    await database.databaseHandle.insert('works', {'title': 'Roundtrip'});
    await database.databaseHandle.insert('images', {
      'work_id': 1,
      'local_path': 'C:/cover.jpg',
      'remote_url': '',
      'caption': '',
      'is_cover': 1,
      'sort_order': 0,
    });
    await database.databaseHandle.insert('catalog_icons', {
      'tier': 'gameSystem',
      'section_name': 'x',
      'local_path': 'C:/icon.png',
    });
    final bundle = '${dir.path}/roundtrip.realmwise';
    await service.exportBundle(database: database, outputPath: bundle);
    final extracted = '${dir.path}/restored.db';
    await service.extractDatabase(bundle, extracted);
    final restored = await databaseFactory.openDatabase(extracted);
    expect((await restored.query('works')).single['title'], 'Roundtrip');
    expect(
      (await restored.query(
        'settings',
        where: 'setting_key = ?',
        whereArgs: ['rpggeek_api_key'],
      )),
      isEmpty,
    );
    expect(
      (await restored.query(
        'settings',
        where: 'setting_key = ?',
        whereArgs: ['theme_seed'],
      )).single['setting_value'],
      'Ocean blue',
    );
    expect((await restored.query('images')).single['local_path'], '');
    expect((await restored.query('catalog_icons')).single['local_path'], '');
    await restored.close();
    await database.close();
  });
  test('checksum mismatch is rejected', () async {
    final p = await makeBundle(checksum: '0000');
    expect(() => service.validateBundle(p), throwsFormatException);
  });
  test('packages owned image and restores it to selected root', () async {
    final dbPath = '${dir.path}/catalog.db';
    final owned = File('${dir.path}/owned.png')..writeAsBytesSync([1, 2, 3]);
    final database = DatabaseService();
    await database.open(dbPath);
    await database.databaseHandle.insert('works', {'title': 'Owned'});
    await database.databaseHandle.insert('images', {
      'work_id': 1,
      'local_path': owned.path,
      'remote_url': '',
      'caption': '',
      'is_cover': 1,
      'sort_order': 0,
      'source_type': 'userImported',
    });
    final bundle = '${dir.path}/owned.realmwise';
    await service.exportBundle(
      database: database,
      outputPath: bundle,
      includePersonalImages: true,
    );
    final restoredDb = '${dir.path}/restored.db';
    final root = '${dir.path}/restored_images';
    await service.extractDatabase(bundle, restoredDb, imageRootPath: root);
    final restored = await databaseFactory.openDatabase(restoredDb);
    final local =
        (await restored.query('images')).single['local_path'] as String;
    expect(File(local).existsSync(), isTrue);
    await restored.close();
    await database.close();
  });
  test('excludes remote cover cache bytes while retaining its URL', () async {
    final database = DatabaseService();
    await database.open('${dir.path}/catalog.db');
    await database.databaseHandle.insert('works', {'title': 'Remote'});
    final cached = File('${dir.path}/cached.png')..writeAsBytesSync([1, 2, 3]);
    await database.databaseHandle.insert('images', {
      'work_id': 1,
      'local_path': cached.path,
      'remote_url': 'https://example.com/cover.png',
      'caption': 'Remote cover',
      'is_cover': 1,
      'sort_order': 0,
      'source_type': 'remoteCache',
    });
    final bundle = '${dir.path}/remote.realmwise';
    await service.exportBundle(database: database, outputPath: bundle);
    final archive = ZipDecoder().decodeBytes(await File(bundle).readAsBytes());
    expect(
      archive.files.any((file) => file.name.contains('cached.png')),
      isFalse,
    );
    final extracted = '${dir.path}/remote.db';
    await service.extractDatabase(bundle, extracted);
    final restored = await databaseFactory.openDatabase(extracted);
    final row = (await restored.query('images')).single;
    expect(row['local_path'], '');
    expect(row['remote_url'], 'https://example.com/cover.png');
    await restored.close();
    await database.close();
  });
  test('database-only export excludes personal assets by default', () async {
    final database = DatabaseService();
    await database.open('${dir.path}/default.db');
    await database.databaseHandle.insert('works', {'title': 'Default'});
    final owned = File('${dir.path}/default.png')..writeAsBytesSync([4, 5]);
    await database.databaseHandle.insert('images', {
      'work_id': 1,
      'local_path': owned.path,
      'source_type': 'userImported',
    });
    final bundle = '${dir.path}/default.realmwise';
    await service.exportBundle(database: database, outputPath: bundle);
    final archive = ZipDecoder().decodeBytes(await File(bundle).readAsBytes());
    expect(archive.files.where((f) => f.name.startsWith('assets/')), isEmpty);
    await database.close();
  });

  test('missing selected asset can cancel export', () async {
    final database = DatabaseService();
    await database.open('${dir.path}/missing.db');
    await database.databaseHandle.insert('works', {'title': 'Missing'});
    await database.databaseHandle.insert('images', {
      'work_id': 1,
      'local_path': '${dir.path}/does-not-exist.png',
      'source_type': 'userImported',
    });
    expect(
      () => service.exportBundle(
        database: database,
        outputPath: '${dir.path}/missing.realmwise',
        includePersonalImages: true,
        missingAssetPolicy: MissingAssetPolicy.cancelExport,
      ),
      throwsStateError,
    );
    await database.close();
  });
  test('missing manifest is rejected', () async {
    final a = Archive()..addFile(ArchiveFile('catalog.db', 3, [1, 2, 3]));
    final p = '${dir.path}/missing.zip';
    await File(p).writeAsBytes(ZipEncoder().encode(a)!);
    expect(() => service.validateBundle(p), throwsFormatException);
  });
  test('unsupported format is rejected', () async {
    final db = await _sqliteBytes(dir);
    final manifest = jsonEncode({
      'format_version': 99,
      'app_version': '1.0.0+1',
      'created_at': 'x',
      'catalog_identity': 'x',
      'database_filename': 'catalog.db',
      'database_sha256': sha256.convert(db).toString(),
    });
    final p = await makeBundle(manifest: manifest);
    expect(() => service.validateBundle(p), throwsFormatException);
  });
  test('malformed database is rejected', () async {
    final p = await makeBundle(db: [1, 2, 3]);
    expect(() => service.validateBundle(p), throwsFormatException);
  });
}

Future<List<int>> _sqliteBytes(Directory dir) async {
  final p = '${dir.path}/seed.db';
  final db = await databaseFactory.openDatabase(p);
  for (final table in [
    'works',
    'copies',
    'images',
    'settings',
    'catalog_icons',
  ]) {
    await db.execute('CREATE TABLE IF NOT EXISTS $table (id INTEGER)');
  }
  await db.close();
  return File(p).readAsBytes();
}
