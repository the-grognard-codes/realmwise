import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'diagnostic_logging.dart';

/// Produces recoverable copies of the active database while the app is running.
class BackupService {
  Timer? _timer;

  Future<void> start({
    required String databasePath,
    required Database database,
  }) async {
    await stop();
    try {
      await createBackup(databasePath: databasePath, database: database);
    } on Object catch (error) {
      DiagnosticDiagnostics.emit(
        DiagnosticSeverity.error,
        'backup.start.error',
        {
          'operation': 'backup_start',
          'outcome': 'failed',
          'errorClass': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(_attemptBackup(databasePath: databasePath, database: database));
    });
  }

  Future<void> _attemptBackup({
    required String databasePath,
    required Database database,
  }) async {
    try {
      await createBackup(databasePath: databasePath, database: database);
    } on Object catch (error) {
      DiagnosticDiagnostics.emit(
        DiagnosticSeverity.warning,
        'backup.create.error',
        {
          'operation': 'backup',
          'outcome': 'failed',
          'errorClass': error.runtimeType.toString(),
        },
      );
      // A future timer tick will retry; catalog editing must never be interrupted by a backup error.
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  Future<File> createBackup({
    required String databasePath,
    required Database database,
  }) async {
    // Checkpoint WAL before copying so a snapshot contains every committed edit.
    await database.rawQuery('PRAGMA wal_checkpoint(FULL)');
    final folder = Directory(path.join(path.dirname(databasePath), 'backups'));
    await folder.create(recursive: true);
    final source = File(databasePath);
    if (!await source.exists())
      throw FileSystemException('Database file not found', databasePath);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final destination = path.join(
      folder.path,
      '${path.basenameWithoutExtension(databasePath)}_$stamp.backup.db',
    );
    final backup = await source.copy(destination);
    await _scrubLegacyToken(backup);
    await _trimBackups(folder);
    return backup;
  }

  Future<void> scrubLegacyTokens(String databasePath) async {
    final folder = Directory(path.join(path.dirname(databasePath), 'backups'));
    if (!await folder.exists()) return;
    final files = await folder
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.backup.db'))
        .cast<File>()
        .toList();
    for (final file in files) {
      try {
        await _scrubLegacyToken(file);
      } on Object catch (error) {
        DiagnosticDiagnostics.emit(
          DiagnosticSeverity.warning,
          'backup.scrub.error',
          {
            'operation': 'backup_scrub',
            'outcome': 'failed',
            'errorClass': error.runtimeType.toString(),
          },
        );
        // A damaged backup must not prevent the active catalog from opening.
      }
    }
  }

  Future<void> _scrubLegacyToken(File file) async {
    Database? db;
    try {
      db = await openDatabase(file.path);
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='settings'",
      );
      if (tables.isNotEmpty) {
        await db.rawQuery('PRAGMA secure_delete = ON');
        await db.delete(
          'settings',
          where: 'setting_key = ?',
          whereArgs: ['rpggeek_api_key'],
        );
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
        await db.execute('VACUUM');
      }
    } finally {
      await db?.close();
    }
  }

  Future<void> _trimBackups(Directory folder) async {
    final files = await folder
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.backup.db'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final oldFile in files.skip(12)) {
      await oldFile.delete();
    }
  }
}
