import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

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
  }) async {
    if (!database.isOpen) throw StateError('No database is currently open.');
    await database.databaseHandle.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    final source = File(database.databasePath);
    if (!await source.exists())
      throw StateError('Active database file is missing.');
    final temp = File('${source.path}.portable.tmp');
    await source.copy(temp.path);
    try {
      final db = await databaseFactory.openDatabase(temp.path);
      try {
        await db.delete(
          'settings',
          where: 'setting_key IN (?, ?, ?, ?)',
          whereArgs: const [
            'rpggeek_api_key',
            'image_folder',
            'theme_seed',
            'catalog_hierarchy_order',
          ],
        );
        await db.update('images', {'local_path': ''});
        await db.update('catalog_icons', {'local_path': ''});
        await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        await db.execute('VACUUM');
      } finally {
        await db.close();
      }
      final bytes = await temp.readAsBytes();
      final identity = database.getSetting('catalog_identity');
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

  Future<String> extractDatabase(String bundlePath, String targetPath) async {
    await validateBundle(bundlePath);
    final archive = ZipDecoder().decodeBytes(
      await File(bundlePath).readAsBytes(),
    );
    final dbFile = archive.files.firstWhere((f) => f.name == databaseEntry);
    await File(
      targetPath,
    ).writeAsBytes(List<int>.from(dbFile.content), flush: true);
    return targetPath;
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
