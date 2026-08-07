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
    expect((await restored.query('images')).single['local_path'], '');
    expect((await restored.query('catalog_icons')).single['local_path'], '');
    await restored.close();
    await database.close();
  });
  test('checksum mismatch is rejected', () async {
    final p = await makeBundle(checksum: '0000');
    expect(() => service.validateBundle(p), throwsFormatException);
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
