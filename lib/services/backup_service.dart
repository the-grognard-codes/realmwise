import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

/// Produces recoverable copies of the active database while the app is running.
class BackupService {
  Timer? _timer;

  Future<void> start({
    required String databasePath,
    required Database database,
  }) async {
    await stop();
    await createBackup(databasePath: databasePath, database: database);
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(_attemptBackup(databasePath: databasePath, database: database));
    });
  }

  Future<void> _attemptBackup(
      {required String databasePath, required Database database}) async {
    try {
      await createBackup(databasePath: databasePath, database: database);
    } on Exception {
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
    await database.execute('PRAGMA wal_checkpoint(FULL)');
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
    await _trimBackups(folder);
    return backup;
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
