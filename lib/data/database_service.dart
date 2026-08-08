import 'dart:io';
import 'dart:math';
import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/catalog_models.dart';

/// Owns the selected SQLite database and all SQL used by the application.
class DatabaseService {
  Database? _database;
  String? _databasePath;

  String get databasePath {
    final value = _databasePath;
    if (value == null) throw StateError('No database is currently open.');
    return value;
  }

  bool get isOpen => _database != null;
  Database get _db =>
      _database ?? (throw StateError('No database is currently open.'));
  Database get databaseHandle => _db;

  Future<void> open(String filePath) async {
    await close();
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    await Directory(path.dirname(filePath)).create(recursive: true);
    _databasePath = filePath;
    _database = await openDatabase(
      filePath,
      version: 5,
      onConfigure: (database) async =>
          database.execute('PRAGMA foreign_keys = ON'),
      onCreate: _createSchema,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''CREATE TABLE IF NOT EXISTS catalog_icons (
            tier TEXT NOT NULL, section_name TEXT NOT NULL, local_path TEXT NOT NULL,
            alignment_x REAL NOT NULL DEFAULT 0, alignment_y REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (tier, section_name)
          )''');
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE catalog_icons ADD COLUMN zoom REAL NOT NULL DEFAULT 1',
          );
        }
        if (oldVersion < 4) {
          for (final definition in _extendedWorkColumns.entries) {
            await _addColumnIfMissing(
              db,
              'works',
              definition.key,
              definition.value,
            );
          }
        }
        if (oldVersion < 5) {
          await _addColumnIfMissing(
            db,
            'images',
            'source_type',
            "TEXT NOT NULL DEFAULT 'userImported'",
          );
          await _addColumnIfMissing(
            db,
            'catalog_icons',
            'source_type',
            "TEXT NOT NULL DEFAULT 'userImported'",
          );
          // Legacy remote URLs were created exclusively by the downloader; make
          // that historical provenance explicit before future saves occur.
          if (await _hasTable(db, 'images')) {
            await db.execute(
              "UPDATE images SET source_type = 'remoteCache' "
              "WHERE remote_url != '' AND (local_path = '' OR caption = 'Remote cover')",
            );
          }
          if (await _hasTable(db, 'catalog_icons')) {
            await db.execute(
              "UPDATE catalog_icons SET source_type = 'packagedAsset' "
              "WHERE replace(local_path, '\\', '/') LIKE 'assets/%'",
            );
          }
        }
      },
    );
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    _databasePath = null;
    await database?.close();
  }

  Future<void> _createSchema(Database database, int version) async {
    await database.execute('''
      CREATE TABLE works (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        isbn13 TEXT,
        title TEXT NOT NULL,
        authors TEXT NOT NULL DEFAULT '[]',
        publisher TEXT NOT NULL DEFAULT '',
        publication_date TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT '',
        page_count INTEGER,
        game_system TEXT NOT NULL DEFAULT '',
        game_setting TEXT NOT NULL DEFAULT '',
        book_type TEXT NOT NULL DEFAULT '',
        remote_cover_url TEXT NOT NULL DEFAULT '',
        open_library_id TEXT NOT NULL DEFAULT '',
        rpggeek_id TEXT NOT NULL DEFAULT '',
        more_info TEXT NOT NULL DEFAULT '',
        designers TEXT NOT NULL DEFAULT '[]',
        artists TEXT NOT NULL DEFAULT '[]',
        production_staff TEXT NOT NULL DEFAULT '[]',
        version TEXT NOT NULL DEFAULT '',
        product_code TEXT NOT NULL DEFAULT '',
        series_code TEXT NOT NULL DEFAULT '',
        dimensions TEXT NOT NULL DEFAULT '',
        series TEXT NOT NULL DEFAULT '[]',
        setting TEXT NOT NULL DEFAULT '[]',
        family TEXT NOT NULL DEFAULT '[]',
        system TEXT NOT NULL DEFAULT '[]',
        category TEXT NOT NULL DEFAULT '[]',
        mechanics TEXT NOT NULL DEFAULT '[]',
        genre TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    await database.execute(
      'CREATE INDEX works_title_idx ON works(title COLLATE NOCASE)',
    );
    await database.execute('CREATE INDEX works_isbn_idx ON works(isbn13)');
    await database.execute('''
      CREATE TABLE copies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
        condition_name TEXT NOT NULL DEFAULT 'good',
        price_paid REAL,
        currency TEXT NOT NULL DEFAULT 'USD',
        acquisition_date TEXT NOT NULL DEFAULT '',
        acquired_source TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        favorite INTEGER NOT NULL DEFAULT 0,
        tags TEXT NOT NULL DEFAULT '[]'
      )
    ''');
    await database.execute('CREATE INDEX copies_work_idx ON copies(work_id)');
    await database.execute('''
      CREATE TABLE images (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
        local_path TEXT NOT NULL,
        remote_url TEXT NOT NULL DEFAULT '',
        caption TEXT NOT NULL DEFAULT '',
        is_cover INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0
        ,source_type TEXT NOT NULL DEFAULT 'userImported'
      )
    ''');
    await database.execute('CREATE INDEX images_work_idx ON images(work_id)');
    await database.execute('''
      CREATE TABLE settings (
        setting_key TEXT PRIMARY KEY,
        setting_value TEXT NOT NULL
      )
    ''');
    await database.execute('''CREATE TABLE catalog_icons (
      tier TEXT NOT NULL, section_name TEXT NOT NULL, local_path TEXT NOT NULL,
      alignment_x REAL NOT NULL DEFAULT 0, alignment_y REAL NOT NULL DEFAULT 0, zoom REAL NOT NULL DEFAULT 1, source_type TEXT NOT NULL DEFAULT 'userImported',
      PRIMARY KEY (tier, section_name)
    )''');
  }

  static const _extendedWorkColumns = <String, String>{
    'more_info': "TEXT NOT NULL DEFAULT ''",
    'designers': "TEXT NOT NULL DEFAULT '[]'",
    'artists': "TEXT NOT NULL DEFAULT '[]'",
    'production_staff': "TEXT NOT NULL DEFAULT '[]'",
    'version': "TEXT NOT NULL DEFAULT ''",
    'product_code': "TEXT NOT NULL DEFAULT ''",
    'series_code': "TEXT NOT NULL DEFAULT ''",
    'dimensions': "TEXT NOT NULL DEFAULT ''",
    'series': "TEXT NOT NULL DEFAULT '[]'",
    'setting': "TEXT NOT NULL DEFAULT '[]'",
    'family': "TEXT NOT NULL DEFAULT '[]'",
    'system': "TEXT NOT NULL DEFAULT '[]'",
    'category': "TEXT NOT NULL DEFAULT '[]'",
    'mechanics': "TEXT NOT NULL DEFAULT '[]'",
    'genre': "TEXT NOT NULL DEFAULT '[]'",
  };

  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final tableRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    if (tableRows.isEmpty) return;
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    if (rows.any((row) => row['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  static Future<bool> _hasTable(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }

  Future<List<CatalogIconMapping>> listCatalogIcons() async {
    final rows = await _db.query(
      'catalog_icons',
      orderBy: 'tier, section_name COLLATE NOCASE',
    );
    return rows.map(CatalogIconMapping.fromRow).toList();
  }

  Future<CatalogIconMapping?> getCatalogIcon(
    String tier,
    String sectionName,
  ) async {
    final rows = await _db.query(
      'catalog_icons',
      where: 'tier = ? AND section_name = ?',
      whereArgs: [tier, sectionName],
      limit: 1,
    );
    return rows.isEmpty ? null : CatalogIconMapping.fromRow(rows.single);
  }

  Future<void> upsertCatalogIcon(CatalogIconMapping mapping) => _db.insert(
    'catalog_icons',
    mapping.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> removeCatalogIcon(String tier, String sectionName) => _db.delete(
    'catalog_icons',
    where: 'tier = ? AND section_name = ?',
    whereArgs: [tier, sectionName],
  );

  Future<List<String>> listCatalogTierSections(String tier) async {
    final column = {
      'gameSystem': 'game_system',
      'gameSetting': 'game_setting',
      'bookType': 'book_type',
    }[tier];
    if (column == null) return const [];
    final rows = await _db.rawQuery(
      "SELECT DISTINCT $column AS value FROM works ORDER BY value COLLATE NOCASE",
    );
    final fallback = {
      'gameSystem': 'Unclassified system',
      'gameSetting': 'Unspecified Setting',
      'bookType': 'Unclassified type',
    }[tier]!;
    return rows
        .map((r) {
          final value = (r['value'] as String?)?.trim() ?? '';
          return value.isEmpty ? fallback : value;
        })
        .toSet()
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<List<CatalogRecord>> listRecords() async {
    final rows = await _db.query('works', orderBy: 'title COLLATE NOCASE');
    return Future.wait(rows.map((row) => getRecord(row['id'] as int)));
  }

  Future<Map<int, Map<String, Object?>>> workTimestamps() async {
    final rows = await _db.query(
      'works',
      columns: const ['id', 'created_at', 'updated_at'],
    );
    return {
      for (final row in rows)
        row['id'] as int: {
          'created_at': row['created_at'],
          'updated_at': row['updated_at'],
        },
    };
  }

  Future<CatalogRecord?> getRecordOrNull(int workId) async {
    final rows = await _db.query(
      'works',
      where: 'id = ?',
      whereArgs: [workId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return getRecord(workId);
  }

  Future<CatalogRecord> getRecord(int workId) async {
    final workRows = await _db.query(
      'works',
      where: 'id = ?',
      whereArgs: [workId],
      limit: 1,
    );
    if (workRows.isEmpty)
      throw StateError('Book record $workId no longer exists.');
    final copies = await _db.query(
      'copies',
      where: 'work_id = ?',
      whereArgs: [workId],
      orderBy: 'id',
    );
    final images = await _db.query(
      'images',
      where: 'work_id = ?',
      whereArgs: [workId],
      orderBy: 'is_cover DESC, sort_order, id',
    );
    return CatalogRecord(
      work: BookWork.fromRow(workRows.single),
      copies: copies.map(UserCopy.fromRow).toList(),
      images: images.map(BookImage.fromRow).toList(),
    );
  }

  Future<CatalogRecord?> findByIsbn(String isbn13) async {
    final cleaned = isbn13.replaceAll(RegExp(r'[^0-9Xx]'), '');
    if (cleaned.isEmpty) return null;
    final rows = await _db.query(
      'works',
      where: 'isbn13 = ?',
      whereArgs: [cleaned],
      orderBy: 'id',
      limit: 1,
    );
    return rows.isEmpty ? null : getRecord(rows.single['id'] as int);
  }

  /// Saves a work atomically, replacing its represented copies and images.
  Future<CatalogRecord> saveRecord(CatalogRecord record) async {
    if (record.work.title.trim().isEmpty)
      throw ArgumentError.value(
        record.work.title,
        'title',
        'A title is required.',
      );
    final deDuplicatedImages = <BookImage>[];
    final coverIndex = record.images.indexWhere((image) => image.isCover);
    for (var i = 0; i < record.images.length; i++) {
      final image = record.images[i];
      deDuplicatedImages.add(
        image.copyWith(
          isCover: coverIndex < 0 ? i == 0 : i == coverIndex,
          sortOrder: i,
        ),
      );
    }
    late int workId;
    await _db.transaction((transaction) async {
      final row = record.work.toRow()..remove('id');
      if (record.work.id == null) {
        workId = await transaction.insert('works', row);
      } else {
        workId = record.work.id!;
        await transaction.update(
          'works',
          row,
          where: 'id = ?',
          whereArgs: [workId],
        );
        await transaction.update(
          'works',
          {'updated_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [workId],
        );
        await transaction.delete(
          'copies',
          where: 'work_id = ?',
          whereArgs: [workId],
        );
        await transaction.delete(
          'images',
          where: 'work_id = ?',
          whereArgs: [workId],
        );
      }
      for (final copy in record.copies) {
        final rowCopy = copy.toRow(workId)..remove('id');
        await transaction.insert('copies', rowCopy);
      }
      for (final image in deDuplicatedImages) {
        final imageRow = image.toRow(workId)..remove('id');
        await transaction.insert('images', imageRow);
      }
    });
    return getRecord(workId);
  }

  /// Imports a fully validated snapshot atomically, replacing relations for each work.
  /// Supplied IDs are retained; absent IDs are generated by SQLite.
  Future<void> importRecords(
    Iterable<CatalogRecord> records, {
    Map<int, Map<String, Object?>> timestampsByWorkId = const {},
  }) async {
    final list = records.toList();
    await _db.transaction((tx) async {
      for (final record in list) {
        final work = record.work;
        final row = work.toRow()..remove('id');
        final suppliedId = work.id;
        late final int workId;
        if (suppliedId == null) {
          workId = await tx.insert('works', row);
        } else {
          final found = await tx.query(
            'works',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [suppliedId],
            limit: 1,
          );
          workId = suppliedId;
          if (found.isEmpty) {
            await tx.insert('works', {...row, 'id': suppliedId});
          } else {
            await tx.update('works', row, where: 'id = ?', whereArgs: [workId]);
          }
        }
        final timestamps = suppliedId == null
            ? const <String, Object?>{}
            : (timestampsByWorkId[suppliedId] ?? const {});
        if (timestamps['created_at'] != null ||
            timestamps['updated_at'] != null) {
          final values = <String, Object?>{};
          if (timestamps['created_at'] != null)
            values['created_at'] = timestamps['created_at'];
          if (timestamps['updated_at'] != null)
            values['updated_at'] = timestamps['updated_at'];
          await tx.update(
            'works',
            values,
            where: 'id = ?',
            whereArgs: [workId],
          );
        } else if (suppliedId != null) {
          await tx.update(
            'works',
            {'updated_at': DateTime.now().toIso8601String()},
            where: 'id = ?',
            whereArgs: [workId],
          );
        }
        await tx.delete('copies', where: 'work_id = ?', whereArgs: [workId]);
        await tx.delete('images', where: 'work_id = ?', whereArgs: [workId]);
        for (final copy in record.copies) {
          final copyRow = copy.toRow(workId);
          if (copy.id == null) copyRow.remove('id');
          await tx.insert('copies', copyRow);
        }
        for (var i = 0; i < record.images.length; i++) {
          final image = record.images[i].copyWith(sortOrder: i);
          final imageRow = image.toRow(workId);
          if (image.id == null) imageRow.remove('id');
          await tx.insert('images', imageRow);
        }
      }
    });
  }

  Future<void> deleteRecord(int workId) =>
      _db.delete('works', where: 'id = ?', whereArgs: [workId]);

  /// Values used by field autocomplete. Queries local data only, even offline.
  Future<List<String>> suggestions(String field, String phrase) async {
    const allowed = {
      'title',
      'publisher',
      'game_system',
      'game_setting',
      'book_type',
      'acquired_source',
    };
    if (!allowed.contains(field) || phrase.trim().length < 3) return const [];
    final pattern = '%${phrase.trim()}%';
    final rows = field == 'acquired_source'
        ? await _db.rawQuery(
            "SELECT DISTINCT acquired_source AS value FROM copies WHERE acquired_source LIKE ? AND acquired_source != '' ORDER BY value COLLATE NOCASE LIMIT 8",
            [pattern],
          )
        : await _db.rawQuery(
            "SELECT DISTINCT $field AS value FROM works WHERE $field LIKE ? AND $field != '' ORDER BY value COLLATE NOCASE LIMIT 8",
            [pattern],
          );
    return rows.map((row) => row['value'] as String).toList();
  }

  Future<List<String>> allTags() async {
    final rows = await _db.query('copies', columns: ['tags']);
    final tags = <String>{};
    for (final row in rows) {
      tags.addAll(UserCopy.fromRow({'tags': row['tags']}).tags);
    }
    final result = tags.where((tag) => tag.trim().isNotEmpty).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  Future<String?> getSetting(String key) async {
    final rows = await _db.query(
      'settings',
      columns: ['setting_value'],
      where: 'setting_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['setting_value'] as String;
  }

  /// Reads the pre-secure-storage RPGGeek token during one-time migration.
  Future<String?> getLegacyRpgGeekKey() => getSetting('rpggeek_api_key');

  /// Removes the pre-secure-storage RPGGeek token after it is copied safely.
  Future<void> deleteLegacyRpgGeekKey() async {
    await _db.execute('PRAGMA secure_delete = ON');
    await _db.delete(
      'settings',
      where: 'setting_key = ?',
      whereArgs: ['rpggeek_api_key'],
    );
    await _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    await _db.execute('VACUUM');
  }

  Future<String> ensureCatalogIdentity() async {
    final existing = await getSetting('catalog_identity');
    if (existing != null && existing.isNotEmpty) return existing;
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final identity = base64UrlEncode(bytes);
    await setSetting('catalog_identity', identity);
    return identity;
  }

  Future<void> setSetting(String key, String value) => _db.insert('settings', {
    'setting_key': key,
    'setting_value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

class CatalogIconMapping {
  const CatalogIconMapping({
    required this.tier,
    required this.sectionName,
    required this.localPath,
    this.alignmentX = 0,
    this.alignmentY = 0,
    this.zoom = 1,
    this.sourceType = ImageSourceType.userImported,
  });
  final String tier, sectionName, localPath;
  final double alignmentX, alignmentY, zoom;
  final ImageSourceType sourceType;
  factory CatalogIconMapping.fromRow(Map<String, Object?> row) =>
      CatalogIconMapping(
        tier: row['tier'] as String,
        sectionName: row['section_name'] as String,
        localPath: row['local_path'] as String,
        alignmentX: (row['alignment_x'] as num?)?.toDouble() ?? 0,
        alignmentY: (row['alignment_y'] as num?)?.toDouble() ?? 0,
        zoom: (row['zoom'] as num?)?.toDouble() ?? 1,
        sourceType: ImageSourceType.parse(
          row['source_type'] as String?,
          localPath: row['local_path'] as String?,
        ),
      );
  Map<String, Object?> toRow() => {
    'tier': tier,
    'section_name': sectionName,
    'local_path': localPath,
    'alignment_x': alignmentX,
    'alignment_y': alignmentY,
    'zoom': zoom,
    'source_type': sourceType.name,
  };
}
