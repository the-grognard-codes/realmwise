import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../data/database_service.dart';

enum MissingAssetPolicy { continueExport, cancelExport }

/// Portable, database-only device sync bundles.
class CatalogBundleService {
  static const formatVersion = 1;
  static const appVersion = '1.0.0+1';
  static const databaseEntry = 'catalog.db';
  static const manifestEntry = 'manifest.json';

  /// Controls what happens when an explicitly selected personal asset is
  /// missing or unreadable at export time.
  static const continueOnMissingAssets = MissingAssetPolicy.continueExport;

  Future<void> exportBundle({
    required DatabaseService database,
    required String outputPath,
    String? imageRootPath,
    bool includePersonalImages = false,
    MissingAssetPolicy missingAssetPolicy = MissingAssetPolicy.continueExport,
  }) async {
    if (!database.isOpen) throw StateError('No database is currently open.');
    final identity = await database.ensureCatalogIdentity();
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
          if (!includePersonalImages || type == 'remoteCache') {
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
        final missingAssets = <String>[];
        for (final row in imageRows) {
          final raw = row['local_path'] as String? ?? '';
          if (!includePersonalImages ||
              raw.isEmpty ||
              row['source_type'] != 'userImported')
            continue;
          final file = File(raw);
          if (await file.exists()) {
            assetFiles[_imageAssetPath(row['id'], raw)] = file;
          } else {
            missingAssets.add(raw);
          }
        }
        if (includePersonalImages)
          for (final row in iconRows) {
            final raw = row['local_path'] as String? ?? '';
            if (raw.isEmpty ||
                raw.replaceAll('\\', '/').startsWith('assets/')) {
              continue;
            }
            final file = File(raw);
            if (await file.exists()) {
              assetFiles[_iconAssetPath(
                    row['tier'],
                    row['section_name'],
                    raw,
                  )] =
                  file;
            } else {
              missingAssets.add(raw);
            }
          }
        if (missingAssets.isNotEmpty &&
            missingAssetPolicy == MissingAssetPolicy.cancelExport) {
          throw StateError(
            'Selected bundle assets are missing or unreadable: ${missingAssets.join(', ')}',
          );
        }
        // Paths are made portable in the copied database; remote caches remain blank.
        for (final row in imageRows) {
          final raw = row['local_path'] as String? ?? '';
          if (!includePersonalImages ||
              raw.isEmpty ||
              (row['source_type'] as String? ?? '') != 'userImported')
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
              !includePersonalImages ||
                  raw.isEmpty ||
                  raw.replaceAll('\\', '/').startsWith('assets/')
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
          else if (!includePersonalImages &&
              raw.isNotEmpty &&
              !raw.replaceAll('\\', '/').startsWith('assets/'))
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
      final fingerprint = await _computeLogicalFingerprint(temp.path, assetFiles);
      final manifest = <String, Object?>{
        'format_version': formatVersion,
        'app_version': appVersion,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'catalog_identity': identity,
        'database_filename': databaseEntry,
        'database_sha256': sha256.convert(bytes).toString(),
        'content_fingerprint': fingerprint,
        'assets': <Map<String, Object?>>[],
      };
      final archive = Archive()
        ..addFile(ArchiveFile(databaseEntry, bytes.length, bytes));
      for (final entry in assetFiles.entries) {
        final data = await entry.value.readAsBytes();
        archive.addFile(ArchiveFile(entry.key, data.length, data));
        (manifest['assets'] as List<Map<String, Object?>>).add({
          'path': entry.key,
          'size': data.length,
          'type': entry.key.startsWith('assets/images/') ? 'image' : 'icon',
          'sha256': sha256.convert(data).toString(),
        });
      }
      // Manifest is assembled after assets so its metadata is complete.
      final manifestBytes = utf8.encode(jsonEncode(manifest));
      archive.addFile(
        ArchiveFile(manifestEntry, manifestBytes.length, manifestBytes),
      );
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
    final declaredAssets = json['assets'];
    if (declaredAssets != null) {
      if (declaredAssets is! List) {
        throw const FormatException('Bundle manifest assets are malformed.');
      }
      final names = <String>{};
      for (final raw in declaredAssets) {
        if (raw is! Map ||
            raw['path'] is! String ||
            raw['size'] is! int ||
            raw['type'] is! String ||
            raw['sha256'] is! String) {
          throw const FormatException('Bundle manifest assets are malformed.');
        }
        final name = raw['path'] as String;
        if (!name.startsWith('assets/') || !names.add(name)) {
          throw const FormatException(
            'Bundle manifest contains invalid assets.',
          );
        }
        final asset = find(name);
        if (asset == null ||
            asset.content.length != raw['size'] ||
            sha256.convert(List<int>.from(asset.content)).toString() !=
                raw['sha256']) {
          throw const FormatException(
            'Bundle asset checksum does not match manifest.',
          );
        }
      }
      final archiveAssetNames = archive.files
          .where((f) => f.name.startsWith('assets/'))
          .map((f) => f.name)
          .toList();
      if (archiveAssetNames.length != archiveAssetNames.toSet().length ||
          !archiveAssetNames.toSet().containsAll(names) ||
          archiveAssetNames.toSet().length != names.length) {
        throw const FormatException(
          'Bundle assets do not match manifest declarations.',
        );
      }
    } else if (archive.files.any((f) => f.name.startsWith('assets/'))) {
      throw const FormatException(
        'Bundle assets do not match manifest declarations.',
      );
    }
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
      final declared = manifest.assets
          .map((a) => a['path'])
          .whereType<String>()
          .toSet();
      for (final file in archive.files.where(
        (f) => declared.contains(f.name) && f.isFile,
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

  Future<String> _computeLogicalFingerprint(
    String databasePath,
    Map<String, File> assets,
  ) async {
    final db = await databaseFactory.openDatabase(databasePath);
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      );
      final state = <String, Object?>{};
      for (final tableRow in tables) {
        final table = tableRow['name'] as String;
        final info = await db.rawQuery('PRAGMA table_info("$table")');
        final columns = info
            .map((r) => r['name'] as String)
            .where((name) => name != 'created_at' && name != 'updated_at')
            .toList();
        final rows = await db.query(table, columns: columns);
        final normalized = rows
            .map((row) => <String, Object?>{
                  for (final c in columns) c: row[c],
                })
            .map(jsonEncode)
            .toList()
          ..sort();
        state[table] = normalized;
      }
      final assetTuples = <Map<String, Object?>>[];
      for (final entry in assets.entries) {
        final data = await entry.value.readAsBytes();
        assetTuples.add({
          'path': entry.key,
          'size': data.length,
          'sha256': sha256.convert(data).toString(),
        });
      }
      assetTuples.sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
      final canonical = jsonEncode({'database': state, 'assets': assetTuples});
      return sha256.convert(utf8.encode(canonical)).toString();
    } finally {
      await db.close();
    }
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
    this.contentFingerprint,
    this.assets = const [],
  });
  final int formatVersion;
  final String appVersion,
      createdAt,
      catalogIdentity,
      databaseFilename,
      databaseSha256;
  final String? contentFingerprint;
  final List<Map<String, dynamic>> assets;
  factory BundleManifest.fromJson(Map<String, dynamic> j) => BundleManifest(
    formatVersion: j['format_version'] as int,
    appVersion: j['app_version'] as String,
    createdAt: j['created_at'] as String,
    catalogIdentity: j['catalog_identity'] as String,
    databaseFilename: j['database_filename'] as String,
    databaseSha256: j['database_sha256'] as String,
    contentFingerprint: j['content_fingerprint'] as String?,
    assets: (j['assets'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false),
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
