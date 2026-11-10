import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../data/database_service.dart';
import 'catalog_bundle_service.dart';
import 'diagnostic_logging.dart';

enum SnapshotKind {
  routine('Automatic'),
  manual('Manual'),
  preImport('Before import'),
  preDownload('Before download'),
  preRemoteOverwrite('Before remote overwrite');

  const SnapshotKind(this.label);
  final String label;
}

class RestorePoint {
  const RestorePoint({
    required this.path,
    required this.kind,
    required this.timestamp,
  });
  final String path;
  final SnapshotKind kind;
  final DateTime timestamp;
  String get name => p.basename(path);
}

/// Owns local snapshots, retention, and rollback of catalog replacements.
class CatalogRecovery {
  CatalogRecovery({
    required this.database,
    Future<void> Function()? waitForSync,
    Future<void> Function(String)? reopen,
    Future<bool> Function()? rehydrate,
    DateTime Function()? clock,
    CatalogBundleService? bundles,
    Future<File> Function(File, String)? copyFile,
    Future<File> Function(File, String)? renameFile,
  }) : waitForSync = waitForSync ?? (() async {}),
       reopen = reopen ?? database.open,
       rehydrate = rehydrate ?? (() async => false),
       clock = clock ?? DateTime.now,
       bundles = bundles ?? CatalogBundleService(),
       copyFile = copyFile ?? ((file, target) => file.copy(target)),
       renameFile = renameFile ?? ((file, target) => file.rename(target));

  final DatabaseService database;
  final Future<void> Function() waitForSync;
  final Future<void> Function(String) reopen;
  final Future<bool> Function() rehydrate;
  final DateTime Function() clock;
  final CatalogBundleService bundles;
  final Future<File> Function(File, String) copyFile, renameFile;
  Timer? _timer;
  Future<void> _snapshots = Future.value();
  int _lastStamp = 0;
  bool isReplacing = false;

  Directory get _folder =>
      Directory(p.join(p.dirname(database.databasePath), 'backups'));
  int _stamp() {
    final now = clock().toUtc().microsecondsSinceEpoch;
    return _lastStamp = now > _lastStamp ? now : _lastStamp + 1;
  }

  String _kindName(SnapshotKind kind) => switch (kind) {
    SnapshotKind.preImport => 'pre-import',
    SnapshotKind.preDownload => 'pre-download',
    SnapshotKind.preRemoteOverwrite => 'pre-remote-overwrite',
    _ => kind.name,
  };

  Future<void> start({bool snapshotNow = true}) async {
    await stop();
    if (snapshotNow) await snapshot(SnapshotKind.routine);
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(
        snapshot(SnapshotKind.routine).then<void>(
          (_) {},
          onError: (Object error) {
            DiagnosticDiagnostics.emit(
              DiagnosticSeverity.warning,
              'backup.create.error',
              {
                'operation': 'backup',
                'outcome': 'failed',
                'errorClass': error.runtimeType.toString(),
              },
            );
          },
        ),
      );
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _snapshots;
  }

  Future<RestorePoint> snapshot(SnapshotKind kind, {List<int>? bundleBytes}) {
    if (isReplacing)
      return Future.error(StateError('Catalog replacement is in progress.'));
    final operation = _snapshots.then(
      (_) => _snapshot(kind, bundleBytes: bundleBytes),
    );
    _snapshots = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<RestorePoint> _snapshot(
    SnapshotKind kind, {
    List<int>? bundleBytes,
  }) async {
    final stamp = _stamp();
    await _folder.create(recursive: true);
    final suffix = bundleBytes == null ? '.backup.db' : '.realmwise';
    final destination = p.join(
      _folder.path,
      '${p.basenameWithoutExtension(database.databasePath)}_${_kindName(kind)}-$stamp$suffix',
    );
    final temporary = File('$destination.tmp');
    try {
      if (bundleBytes == null) {
        final result = await database.databaseHandle.rawQuery(
          'PRAGMA wal_checkpoint(FULL)',
        );
        if (result.isNotEmpty && result.first.values.first != 0)
          throw StateError('Catalog is busy; snapshot was not created.');
        await File(database.databasePath).copy(temporary.path);
        await _scrub(temporary);
      } else {
        await temporary.writeAsBytes(bundleBytes, flush: true);
        await bundles.validateBundle(temporary.path);
        // Re-export through the bundle writer to remove legacy secrets.
        final extracted = '$destination.scrub.tmp';
        final clean = DatabaseService();
        try {
          await bundles.extractDatabase(
            temporary.path,
            extracted,
            imageRootPath: '$destination.assets.tmp',
          );
          await _scrub(File(extracted));
          await clean.open(extracted);
          await clean.deleteLegacyRpgGeekKey();
          await bundles.exportBundle(
            database: clean,
            outputPath: temporary.path,
            includePersonalImages: true,
          );
        } finally {
          await clean.close();
          if (await File(extracted).exists()) await File(extracted).delete();
          if (await Directory('$destination.assets.tmp').exists())
            await Directory('$destination.assets.tmp').delete(recursive: true);
        }
      }
      await temporary.rename(destination);
      await _trim(kind);
      return RestorePoint(
        path: destination,
        kind: kind,
        timestamp: DateTime.fromMicrosecondsSinceEpoch(stamp, isUtc: true),
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<List<RestorePoint>> restorePoints() async {
    if (!await _folder.exists()) return [];
    final points = <RestorePoint>[];
    await for (final entity in _folder.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.backup.db') &&
          !name.contains('_pre-remote-overwrite-'))
        continue;
      if (!name.endsWith('.backup.db') && !name.endsWith('.realmwise'))
        continue;
      final kind =
          SnapshotKind.values
              .where((kind) => name.contains('_${_kindName(kind)}-'))
              .firstOrNull ??
          SnapshotKind.routine;
      final stamp = RegExp(r'-(\d{13,})(?:\.backup\.db|\.realmwise)$')
          .firstMatch(name);
      try {
        var timestamp = (await entity.stat()).modified.toUtc();
        final legacy = RegExp(
          r'_(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})(?:-(\d+))?',
        ).firstMatch(name);
        if (legacy != null) {
          timestamp =
              DateTime.tryParse(
                '${legacy[1]}T${legacy[2]}:${legacy[3]}:${legacy[4]}.${legacy[5] ?? "000"}',
              )?.toUtc() ??
              timestamp;
        } else if (stamp != null) {
          try {
            timestamp = DateTime.fromMicrosecondsSinceEpoch(
              int.parse(stamp[1]!),
              isUtc: true,
            );
          } on ArgumentError {
            /* Keep the filesystem date for an invalid legacy name. */
          } on FormatException {
            /* Keep the filesystem date for an invalid legacy name. */
          }
        }
        points.add(
          RestorePoint(path: entity.path, kind: kind, timestamp: timestamp),
        );
      } on FileSystemException {
        /* A restore point may have disappeared. */
      }
    }
    points.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return points;
  }

  Future<void> _trim(SnapshotKind kind) async {
    final prefix = '${p.basenameWithoutExtension(database.databasePath)}_';
    final points = (await restorePoints()).where(
      (point) =>
          point.kind == kind && p.basename(point.path).startsWith(prefix),
    );
    for (final old in points.skip(kind == SnapshotKind.routine ? 12 : 5)) {
      await File(old.path).delete();
    }
  }

  Future<void> scrubLegacyTokens() async {
    for (final point in await restorePoints()) {
      if (!point.path.endsWith('.backup.db')) continue;
      try {
        await _scrub(File(point.path));
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
      }
    }
  }

  Future<void> _scrub(File file) async {
    final db = await databaseFactory.openDatabase(file.path);
    try {
      if ((await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='settings'",
      )).isEmpty)
        return;
      await db.execute('PRAGMA secure_delete = ON');
      await db.delete(
        'settings',
        where: 'setting_key = ? OR setting_key LIKE ? OR setting_key LIKE ?',
        whereArgs: ['rpggeek_api_key', '%oauth%token%', 'cloud_sync_token%'],
      );
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      await db.execute('VACUUM');
    } finally {
      await db.close();
    }
  }

  Future<void> _validate(String file) async {
    final db = await databaseFactory.openDatabase(
      file,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      final result = await db.rawQuery('PRAGMA integrity_check');
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((row) => row['name']).toSet();
      if (result.first.values.first != 'ok' ||
          !tables.containsAll({
            'works',
            'copies',
            'images',
            'settings',
            'catalog_icons',
          })) {
        throw const FormatException('Not a valid Realmwise catalog.');
      }
    } finally {
      await db.close();
    }
  }

  /// A bundle or database is staged beside the active file before quiescing.
  /// Successful imported images remain in their unique restore namespace.
  Future<void> replaceCatalog(
    String sourcePath, {
    SnapshotKind snapshotKind = SnapshotKind.preImport,
    bool bundle = false,
    String? imageRootPath,
  }) async {
    if (isReplacing)
      throw StateError('Catalog replacement is already in progress.');
    if (!database.isOpen) throw StateError('No active database to replace.');
    isReplacing = true;
    final active = database.databasePath;
    final stamp = _stamp();
    final staged = '$active.replace-$stamp.tmp';
    final rollback = '$active.rollback-$stamp.tmp';
    final imageStaging = imageRootPath == null
        ? null
        : p.join(imageRootPath, 'recovery-$stamp');
    var moved = false, committed = false, quiesced = false;
    try {
      if (bundle) {
        await bundles.extractDatabase(
          sourcePath,
          staged,
          imageRootPath: imageStaging,
        );
      } else {
        await File(sourcePath).copy(staged);
      }
      await _validate(staged);
      await waitForSync();
      await stop();
      quiesced = true;
      await _snapshot(snapshotKind);
      await database.close();
      // Copy first so copy failure cannot destroy the original catalog.
      await copyFile(File(staged), '$staged.ready');
      await renameFile(File(active), rollback);
      moved = true;
      await renameFile(File('$staged.ready'), active);
      await reopen(active);
      await rehydrate();
      committed = true;
    } catch (_) {
      if (quiesced) {
        await database.close();
        if (moved) {
          if (await File(active).exists()) await File(active).delete();
          // Rollback deliberately uses native operations, independent of a
          // failing injected replacement operation.
          await File(rollback).rename(active);
        }
        await reopen(active);
      }
      rethrow;
    } finally {
      for (final file in [staged, '$staged.ready']) {
        if (await File(file).exists()) await File(file).delete();
      }
      if (committed && await File(rollback).exists())
        await File(rollback).delete();
      if (!committed &&
          imageStaging != null &&
          await Directory(imageStaging).exists()) {
        await Directory(imageStaging).delete(recursive: true);
      }
      isReplacing = false;
      if (quiesced && database.isOpen) await start(snapshotNow: false);
    }
  }
}
