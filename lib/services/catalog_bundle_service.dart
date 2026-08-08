import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../data/database_service.dart';

/// Portable, database-only device sync bundles.
class CatalogBundleService {
  static const formatVersion = 1;
  static const appVersion = '1.0.0+1';
  static const databaseEntry = 'catalog.db';
  static const manifestEntry = 'manifest.json';

  Future<void> exportBundle({
    required DatabaseService database,
    required String outputPath,
    String? imageRootPath,
  }) async {
    if (!database.isOpen) throw StateError('No database is currently open.');
    await database.databaseHandle.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    final source = File(database.databasePath);
    if (!await source.exists())
      throw StateError('Active database file is missing.');
    final temp = File('${source.path}.portable.tmp');
    final assetFiles = <String, File>{};
    await source.copy(temp.path);
    try {
      final db = await databaseFactory.openDatabase(temp.path);
      try {
        await db.delete(
          'settings',
          where: 'setting_key IN (?, ?, ?)',
          whereArgs: const [
            'rpggeek_api_key',
            'image_folder',
            'catalog_hierarchy_order',
          ],
        );
        final imageRows = await db.query(
          'images',
          columns: ['id', 'local_path', 'source_type'],
        );
        for (final row in imageRows) {
          final type = row['source_type'] as String? ?? 'userImported';
          if (type == 'remoteCache') {
            await db.update(
              'images',
              {'local_path': ''},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
        }
        final iconRows = await db.query(
          'catalog_icons',
          columns: ['tier', 'section_name', 'local_path'],
        );
        for (final row in imageRows) {
          final raw = row['local_path'] as String? ?? '';
          if (raw.isEmpty || row['source_type'] == 'remoteCache') continue;
          final file = File(raw);
          if (await file.exists()) {
            assetFiles[_imageAssetPath(row['id'], raw)] = file;
          }
        }
        for (final row in iconRows) {
          final raw = row['local_path'] as String? ?? '';
          if (raw.isEmpty || raw.replaceAll('\\', '/').startsWith('assets/')) {
            continue;
          }
          final file = File(raw);
          if (await file.exists()) {
            assetFiles[_iconAssetPath(row['tier'], row['section_name'], raw)] =
                file;
          }
        }
        // Paths are made portable in the copied database; remote caches remain blank.
        for (final row in imageRows) {
          final raw = row['local_path'] as String? ?? '';
          if (raw.isEmpty ||
              (row['source_type'] as String? ?? '') == 'remoteCache')
            continue;
          final key = _imageAssetPath(row['id'], raw);
          if (assetFiles.containsKey(key)) {
            await db.update(
              'images',
              {'local_path': key},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          } else {
            await db.update(
              'images',
              {'local_path': ''},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
        }
        for (final row in iconRows) {
          final raw = row['local_path'] as String? ?? '';
          final key =
              raw.isEmpty || raw.replaceAll('\\', '/').startsWith('assets/')
              ? ''
              : _iconAssetPath(row['tier'], row['section_name'], raw);
          if (key.isNotEmpty && assetFiles.containsKey(key))
            await db.update(
              'catalog_icons',
              {'local_path': key},
              where: 'tier = ? AND section_name = ?',
              whereArgs: [row['tier'], row['section_name']],
            );
          else if (key.isNotEmpty)
            await db.update(
              'catalog_icons',
              {'local_path': ''},
              where: 'tier = ? AND section_name = ?',
              whereArgs: [row['tier'], row['section_name']],
            );
        }
        await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        await db.execute('VACUUM');
      } finally {
        await db.close();
      }
      final bytes = await temp.readAsBytes();
      final identity = database.ensureCatalogIdentity();
      final manifest = <String, Object?>{
        'format_version': formatVersion,
        'app_version': appVersion,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'catalog_identity': await identity,
        'database_filename': databaseEntry,
        'database_sha256': sha256.convert(bytes).toString(),
      };
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            manifestEntry,
            utf8.encode(jsonEncode(manifest)).length,
            utf8.encode(jsonEncode(manifest)),
          ),
        )
        ..addFile(ArchiveFile(databaseEntry, bytes.length, bytes));
      for (final entry in assetFiles.entries) {
        final data = await entry.value.readAsBytes();
        archive.addFile(ArchiveFile(entry.key, data.length, data));
      }
      final encoded = ZipEncoder().encode(archive);
      if (encoded == null) throw StateError('Could not encode catalog bundle.');
      await File(outputPath).writeAsBytes(encoded, flush: true);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<BundleManifest> validateBundle(String bundlePath) async {
    final file = File(bundlePath);
    if (!await file.exists())
      throw const FormatException('Bundle file does not exist.');
    late Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    } catch (_) {
      throw const FormatException('Bundle is not a valid archive.');
    }
    ArchiveFile? find(String name) =>
        archive.files.where((f) => f.name == name).firstOrNull;
    final manifestFile = find(manifestEntry);
    final dbFile = find(databaseEntry);
    if (manifestFile == null)
      throw const FormatException('Bundle is missing manifest.json.');
    if (dbFile == null)
      throw const FormatException('Bundle is missing catalog.db.');
    late Map<String, dynamic> json;
    try {
      json =
          jsonDecode(utf8.decode(manifestFile.content as List<int>))
              as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Bundle manifest is malformed.');
    }
    if (json['format_version'] != formatVersion)
      throw FormatException(
        'Unsupported bundle format version: ${json['format_version']}.',
      );
    for (final key in [
      'created_at',
      'app_version',
      'catalog_identity',
      'database_filename',
      'database_sha256',
    ]) {
      if (json[key] is! String || (json[key] as String).isEmpty)
        throw FormatException('Bundle manifest is missing $key.');
    }
    final bytes = List<int>.from(dbFile.content as List<int>);
    if (sha256.convert(bytes).toString() != json['database_sha256'])
      throw const FormatException(
        'Bundle database checksum does not match manifest.',
      );
    final temp = File('${file.path}.validate.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    try {
      final db = await databaseFactory.openDatabase(temp.path);
      try {
        final integrity = await db.rawQuery('PRAGMA integrity_check');
        if (integrity.isEmpty || integrity.first.values.first != 'ok') {
          throw const FormatException(
            'Bundle database failed integrity check.',
          );
        }
        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        );
        const required = {
          'works',
          'copies',
          'images',
          'settings',
          'catalog_icons',
        };
        if (!required.every(
          (name) => tables.any((row) => row['name'] == name),
        )) {
          throw const FormatException(
            'Bundle database schema is not a Realmwise catalog.',
          );
        }
      } finally {
        await db.close();
      }
    } catch (_) {
      throw const FormatException(
        'Bundle database is malformed or unreadable.',
      );
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    return BundleManifest.fromJson(json);
  }

  Future<String> extractDatabase(
    String bundlePath,
    String targetPath, {
    String? imageRootPath,
  }) async {
    final manifest = await validateBundle(bundlePath);
    final archive = ZipDecoder().decodeBytes(
      await File(bundlePath).readAsBytes(),
    );
    final dbFile = archive.files.firstWhere((f) => f.name == databaseEntry);
    await File(
      targetPath,
    ).writeAsBytes(List<int>.from(dbFile.content), flush: true);
    if (imageRootPath != null) {
      // A bundle's own namespace prevents similarly named files from another
      // restored catalog from overwriting this catalog's images.
      final root = Directory(
        p.join(imageRootPath, 'restored', manifest.catalogIdentity),
      )..createSync(recursive: true);
      for (final file in archive.files.where(
        (f) => f.name.startsWith('assets/') && f.isFile,
      )) {
        final out = File(p.join(root.path, p.basename(file.name)));
        await out.writeAsBytes(List<int>.from(file.content), flush: true);
      }
      final db = await databaseFactory.openDatabase(targetPath);
      try {
        final rows = await db.query('images', columns: ['id', 'local_path']);
        for (final row in rows) {
          final raw = row['local_path'] as String? ?? '';
          if (raw.startsWith('assets/images/'))
            await db.update(
              'images',
              {'local_path': p.join(root.path, p.basename(raw))},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
        }
        final icons = await db.query(
          'catalog_icons',
          columns: ['tier', 'section_name', 'local_path'],
        );
        for (final row in icons) {
          final raw = row['local_path'] as String? ?? '';
          if (raw.startsWith('assets/icons/'))
            await db.update(
              'catalog_icons',
              {'local_path': p.join(root.path, p.basename(raw))},
              where: 'tier = ? AND section_name = ?',
              whereArgs: [row['tier'], row['section_name']],
            );
        }
      } finally {
        await db.close();
      }
    }
    return targetPath;
  }

  static String _imageAssetPath(Object? id, String localPath) =>
      'assets/images/${id ?? 'new'}_${p.basename(localPath)}';

  static String _iconAssetPath(
    Object? tier,
    Object? sectionName,
    String localPath,
  ) {
    final identity = sha256
        .convert(utf8.encode('$tier\u0000$sectionName'))
        .toString()
        .substring(0, 16);
    return 'assets/icons/${identity}_${p.basename(localPath)}';
  }
}

class BundleManifest {
  const BundleManifest({
    required this.formatVersion,
    required this.appVersion,
    required this.createdAt,
    required this.catalogIdentity,
    required this.databaseFilename,
    required this.databaseSha256,
  });
  final int formatVersion;
  final String appVersion,
      createdAt,
      catalogIdentity,
      databaseFilename,
      databaseSha256;
  factory BundleManifest.fromJson(Map<String, dynamic> j) => BundleManifest(
    formatVersion: j['format_version'] as int,
    appVersion: j['app_version'] as String,
    createdAt: j['created_at'] as String,
    catalogIdentity: j['catalog_identity'] as String,
    databaseFilename: j['database_filename'] as String,
    databaseSha256: j['database_sha256'] as String,
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
