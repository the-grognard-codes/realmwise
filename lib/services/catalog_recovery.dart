import 'dart:async';
import 'dart:convert';
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
  preRestore('Before restore'),
  preConflict('Before conflict'),
  preDownload('Before download'),
  preRemoteOverwrite('Before remote overwrite');

  const SnapshotKind(this.label);
  final String label;
}

enum RestorePointFormat { database, bundle }

class CatalogRecoveryWarning {
  const CatalogRecoveryWarning({required this.originalPath});
  final String originalPath;

  String get message =>
      'Catalog replacement needs review. Automatic sync is paused until you '
      'acknowledge the active catalog. The original was protected by a recovery '
      'snapshot; its rollback location is $originalPath.';
}

class CatalogReplacementResult {
  const CatalogReplacementResult({this.warning});
  final CatalogRecoveryWarning? warning;
  bool get needsAcknowledgement => warning != null;
}

class RestorePoint {
  const RestorePoint({
    required this.path,
    required this.kind,
    required this.timestamp,
    this.format = RestorePointFormat.database,
  });
  final String path;
  final SnapshotKind kind;
  final RestorePointFormat format;
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
    Future<void> Function()? onReady,
    DateTime Function()? clock,
    CatalogBundleService? bundles,
    Future<File> Function(File, String)? copyFile,
    Future<File> Function(File, String)? renameFile,
    Future<void> Function(File)? deleteFile,
  }) : waitForSync = waitForSync ?? (() async {}),
       reopen = reopen ?? database.open,
       rehydrate = rehydrate ?? (() async => false),
       onReady = onReady ?? (() async {}),
       clock = clock ?? DateTime.now,
       bundles = bundles ?? CatalogBundleService(),
       copyFile = copyFile ?? ((file, target) => file.copy(target)),
       renameFile = renameFile ?? ((file, target) => file.rename(target)),
       deleteFile =
           deleteFile ??
           ((file) async {
             await file.delete();
           });

  final DatabaseService database;
  final Future<void> Function() waitForSync;
  final Future<void> Function(String) reopen;
  final Future<bool> Function() rehydrate;
  final Future<void> Function() onReady;
  final DateTime Function() clock;
  final CatalogBundleService bundles;
  final Future<File> Function(File, String) copyFile, renameFile;
  final Future<void> Function(File) deleteFile;
  Timer? _timer;
  Future<void> _snapshots = Future.value();
  int _lastStamp = 0;
  bool _isReplacing = false;
  bool get isReplacing => _isReplacing;
  bool _quiesced = false;
  final Set<String> _pendingFileCleanup = {};
  CatalogRecoveryWarning? warning;

  File get _warningFile =>
      File('${database.databasePath}.recovery-review.json');

  /// The marker is outside the replaceable database and survives app restarts.
  Future<void> loadWarning() async {
    final file = _warningFile;
    warning = null;
    if (!await file.exists()) return;
    // Even an interrupted marker write must keep automatic uploads blocked.
    warning = const CatalogRecoveryWarning(
      originalPath: 'See local restore points',
    );
    try {
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      warning = CatalogRecoveryWarning(
        originalPath: value['originalPath'] as String,
      );
    } on Object catch (error) {
      _reportFailure('warning_read', error);
    }
  }

  Future<void> acknowledgeWarning() async {
    if (isReplacing) throw StateError('Catalog replacement is in progress.');
    if (await _warningFile.exists()) await _warningFile.delete();
    warning = null;
  }

  Directory get _folder =>
      Directory(p.join(p.dirname(database.databasePath), 'backups'));
  int _stamp() {
    final now = clock().toUtc().microsecondsSinceEpoch;
    return _lastStamp = now > _lastStamp ? now : _lastStamp + 1;
  }

  String _kindName(SnapshotKind kind) => switch (kind) {
    SnapshotKind.preImport => 'pre-import',
    SnapshotKind.preRestore => 'pre-restore',
    SnapshotKind.preConflict => 'pre-conflict',
    SnapshotKind.preDownload => 'pre-download',
    SnapshotKind.preRemoteOverwrite => 'pre-remote-overwrite',
    _ => kind.name,
  };

  Future<void> start({bool snapshotNow = true}) async {
    await stop();
    await loadWarning();
    await _retryFileCleanup();
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
    if (_quiesced)
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
    await _retryFileCleanup();
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
        await _checkpoint('FULL');
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
          await _deleteDatabaseFiles(extracted);
          if (await Directory('$destination.assets.tmp').exists())
            await Directory('$destination.assets.tmp').delete(recursive: true);
        }
      }
      await temporary.rename(destination);
      await _trim(kind);
      return RestorePoint(
        path: destination,
        kind: kind,
        format: bundleBytes == null
            ? RestorePointFormat.database
            : RestorePointFormat.bundle,
        timestamp: DateTime.fromMicrosecondsSinceEpoch(stamp, isUtc: true),
      );
    } finally {
      await _deleteDatabaseFiles(temporary.path);
    }
  }

  Future<List<RestorePoint>> restorePoints() async {
    if (!await _folder.exists()) return [];
    final points = <RestorePoint>[];
    await for (final entity in _folder.list()) {
      if (entity is! File) continue;
      final prefix = '${p.basenameWithoutExtension(database.databasePath)}_';
      final name = p.basename(entity.path);
      if (!name.startsWith(prefix)) continue;
      final suffix = name.substring(prefix.length);
      final typed = RegExp(
        '^(${SnapshotKind.values.map(_kindName).join('|')})-(\\d{13,})(\\.backup\\.db|\\.realmwise)\$',
      ).firstMatch(suffix);
      final legacy = RegExp(
        r'^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})(?:-(\d+))?\.backup\.db$',
      ).firstMatch(suffix);
      if (typed == null && legacy == null) continue;
      final kind = typed == null
          ? SnapshotKind.routine
          : SnapshotKind.values.firstWhere(
              (kind) => _kindName(kind) == typed[1],
            );
      try {
        var timestamp = (await entity.stat()).modified.toUtc();
        if (legacy != null) {
          timestamp =
              DateTime.tryParse(
                '${legacy[1]}T${legacy[2]}:${legacy[3]}:${legacy[4]}.${legacy[5] ?? "000"}',
              )?.toUtc() ??
              timestamp;
        } else if (typed != null) {
          try {
            timestamp = DateTime.fromMicrosecondsSinceEpoch(
              int.parse(typed[2]!),
              isUtc: true,
            );
          } on ArgumentError {
            /* Keep the filesystem date for an invalid legacy name. */
          } on FormatException {
            /* Keep the filesystem date for an invalid legacy name. */
          }
        }
        points.add(
          RestorePoint(
            path: entity.path,
            kind: kind,
            timestamp: timestamp,
            format: suffix.endsWith('.realmwise')
                ? RestorePointFormat.bundle
                : RestorePointFormat.database,
          ),
        );
      } on FileSystemException {
        /* A restore point may have disappeared. */
      }
    }
    points.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return points;
  }

  Future<void> _trim(SnapshotKind kind) async {
    final points = (await restorePoints()).where((point) => point.kind == kind);
    for (final old in points.skip(kind == SnapshotKind.routine ? 12 : 5)) {
      await _deleteDatabaseFiles(old.path);
    }
  }

  Future<RestorePoint> inspectRestorePoint(String file) async {
    final format = file.endsWith('.realmwise') || file.endsWith('.zip')
        ? RestorePointFormat.bundle
        : RestorePointFormat.database;
    if (format == RestorePointFormat.bundle) {
      await bundles.validateBundle(file);
    } else {
      await _validate(file);
    }
    return RestorePoint(
      path: file,
      kind: SnapshotKind.manual,
      timestamp: (await File(file).stat()).modified.toUtc(),
      format: format,
    );
  }

  Future<CatalogReplacementResult> restore(
    RestorePoint point, {
    String? imageRootPath,
  }) => replaceCatalog(
    point.path,
    snapshotKind: SnapshotKind.preRestore,
    bundle: point.format == RestorePointFormat.bundle,
    imageRootPath: imageRootPath,
  );

  static const _catalogBusyMessage =
      'The catalog is busy with an export or another connection. '
      'Wait for it to finish and retry this operation.';

  Future<void> _checkpoint(String mode) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final rows = await database.databaseHandle.rawQuery(
        'PRAGMA wal_checkpoint($mode)',
      );
      final row = rows.single;
      if (row['busy'] == 0 && row['log'] == row['checkpointed']) return;
      if (attempt < 2)
        await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError(_catalogBusyMessage);
  }

  Future<void> _verifyEmptyWal(String file) async {
    final wal = File('$file-wal');
    if (await wal.exists() && await wal.length() != 0) {
      throw StateError(_catalogBusyMessage);
    }
  }

  Future<void> _checkpointForReplacement() async {
    await _checkpoint('TRUNCATE');
    await _verifyEmptyWal(database.databasePath);
  }

  Future<void> _discardEmptyWal(String file) async {
    await _verifyEmptyWal(file);
    final wal = File('$file-wal');
    if (await wal.exists()) await wal.delete();
  }

  Future<void> _moveSidecars(
    String source,
    String destination,
    Future<File> Function(File, String) rename,
  ) async {
    for (final suffix in ['-shm', '-journal']) {
      final file = File('$source$suffix');
      if (!await file.exists()) continue;
      if (await File('$destination$suffix').exists()) {
        throw FileSystemException(
          'Catalog sidecar destination already exists.',
          '$destination$suffix',
        );
      }
      await rename(file, '$destination$suffix');
    }
  }

  Future<void> _deleteSidecars(String file) async {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final sidecar = File('$file$suffix');
      if (await sidecar.exists()) await deleteFile(sidecar);
    }
  }

  Future<void> _deleteDatabaseFiles(String file) async {
    if (await File(file).exists()) await deleteFile(File(file));
    await _deleteSidecars(file);
  }

  Future<void> _cleanupDatabaseFiles(String file) async {
    final marker = File('$file.cleanup-pending');
    try {
      // Only staged copies and committed rollbacks reach this method. Record
      // intent before deletion so a new process can safely finish cleanup.
      await marker.writeAsString('', flush: true);
      await _deleteDatabaseFiles(file);
      await marker.delete();
      _pendingFileCleanup.remove(file);
    } on Object catch (error) {
      _pendingFileCleanup.add(file);
      _reportFailure('cleanup', error);
    }
  }

  Future<void> _retryFileCleanup() async {
    if (isReplacing || !database.isOpen) return;
    final active = database.databasePath;
    final folder = Directory(p.dirname(active));
    final pattern = RegExp(
      '^${RegExp.escape(p.basename(active))}'
      r'\.(?:replace-\d+\.tmp(?:\.ready)?|rollback-\d+\.tmp)\.cleanup-pending$',
      caseSensitive: !Platform.isWindows,
    );
    final stagedPattern = RegExp(
      '^${RegExp.escape(p.basename(active))}'
      r'\.replace-\d+\.tmp(?:\.ready)?$',
      caseSensitive: !Platform.isWindows,
    );
    // Staged copies can survive a crash before finally records cleanup intent.
    // Rollbacks still require intent: an unmarked one may be the original.
    try {
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is! File) continue;
        if (stagedPattern.hasMatch(p.basename(entry.path))) {
          _pendingFileCleanup.add(entry.path);
        } else if (pattern.hasMatch(p.basename(entry.path))) {
          _pendingFileCleanup.add(
            entry.path.substring(
              0,
              entry.path.length - '.cleanup-pending'.length,
            ),
          );
        }
      }
    } on Object catch (error) {
      _reportFailure('cleanup_scan', error);
    }
    for (final file in _pendingFileCleanup.toList()) {
      if (database.isOpen && p.equals(file, database.databasePath)) continue;
      if (warning != null && p.equals(file, warning!.originalPath)) continue;
      await _cleanupDatabaseFiles(file);
    }
  }

  void _reportFailure(String operation, Object error) {
    DiagnosticDiagnostics.emit(
      DiagnosticSeverity.warning,
      'recovery.$operation.error',
      {
        'operation': operation,
        'outcome': 'failed',
        'errorClass': error.runtimeType.toString(),
      },
    );
  }

  Future<void> scrubLegacyTokens() async {
    if (!await _folder.exists()) return;
    // Privacy migration also covers old snapshots with unrecognized names.
    // Listing and retention remain scoped to the active catalog.
    await for (final file in _folder.list()) {
      if (file is! File || !file.path.endsWith('.backup.db')) continue;
      try {
        await _scrub(file);
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
  Future<CatalogReplacementResult> replaceCatalog(
    String sourcePath, {
    SnapshotKind snapshotKind = SnapshotKind.preImport,
    bool bundle = false,
    String? imageRootPath,
  }) async {
    if (isReplacing)
      throw StateError('Catalog replacement is already in progress.');
    if (!database.isOpen) throw StateError('No active database to replace.');
    _isReplacing = true;
    final active = database.databasePath;
    final warningFile = _warningFile;
    final stamp = _stamp();
    final staged = '$active.replace-$stamp.tmp';
    final rollback = '$active.rollback-$stamp.tmp';
    final imageStaging = imageRootPath == null
        ? null
        : p.join(imageRootPath, 'recovery-$stamp');
    var moved = false, committed = false, quiesced = false;
    var closing = false, installed = false, replacementRetained = false;
    var ownsWarning = false;
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
      _quiesced = true;
      await _snapshot(snapshotKind);
      await _checkpointForReplacement();
      await loadWarning();
      if (warning == null) {
        // Persist before closing or replacing anything. A process interruption
        // therefore cannot silently resume automatic uploads of an unreviewed catalog.
        warning = CatalogRecoveryWarning(originalPath: rollback);
        await warningFile.writeAsString(
          jsonEncode({'originalPath': rollback}),
          flush: true,
        );
        ownsWarning = true;
      }
      closing = true;
      await database.close();
      // Copy first so copy failure cannot destroy the original catalog.
      await copyFile(File(staged), '$staged.ready');
      // A WAL with committed pages must remain beside its original catalog.
      // Refuse a concurrent writer; only an empty, checkpointed WAL is discarded.
      await _discardEmptyWal(active);
      await renameFile(File(active), rollback);
      moved = true;
      await _moveSidecars(active, rollback, renameFile);
      await renameFile(File('$staged.ready'), active);
      installed = true;
      await reopen(active);
      await rehydrate();
      committed = true;
    } catch (error) {
      if (closing) {
        var originalRestored = !moved;
        try {
          await database.close();
          if (moved) {
            if (installed) await _deleteDatabaseFiles(active);
            await File(rollback).rename(active);
            originalRestored = true;
          }
        } on Object catch (rollbackError) {
          _reportFailure('rollback', rollbackError);
        }
        if (!originalRestored) {
          try {
            // A Windows delete can fail while replacing via rename still works.
            // Remove replacement sidecars first so none can attach to the original.
            if (installed) await _deleteSidecars(active);
            await renameFile(File(rollback), active);
            originalRestored = true;
          } on Object catch (retryError) {
            _reportFailure('rollback', retryError);
          }
        }
        replacementRetained =
            !originalRestored && installed && await File(active).exists();
        if (originalRestored) {
          if (moved) {
            try {
              await _moveSidecars(
                rollback,
                active,
                (file, target) => file.rename(target),
              );
            } on Object catch (sidecarError) {
              _reportFailure('rollback', sidecarError);
            }
          }
        }
        if (originalRestored || replacementRetained) {
          // Even if the original cannot return, keep the installed catalog usable.
          // Its rollback file and referenced images remain available for recovery.
          try {
            await reopen(active);
          } on Object catch (reopenError) {
            _reportFailure('rollback', reopenError);
          }
        }
      }
      if (!replacementRetained || !database.isOpen) rethrow;
      _reportFailure('replacement_retained', error);
    } finally {
      // Temporary-file locks do not change which catalog committed. Attempt
      // every cleanup independently and retry failures on later snapshots.
      for (final file in [staged, '$staged.ready', if (committed) rollback]) {
        await _cleanupDatabaseFiles(file);
      }
      try {
        if (!committed &&
            !replacementRetained &&
            imageStaging != null &&
            await Directory(imageStaging).exists()) {
          await Directory(imageStaging).delete(recursive: true);
        }
      } on Object catch (cleanupError) {
        _reportFailure('cleanup', cleanupError);
      }
      // A deliberate replacement that fully committed resolves any earlier
      // warning; merely failing to restore the original does not.
      if ((committed || ownsWarning) && !replacementRetained) {
        try {
          if (await warningFile.exists()) await warningFile.delete();
          warning = null;
        } on Object catch (warningError) {
          _reportFailure('warning_clear', warningError);
        }
      }
      _quiesced = false;
      _isReplacing = false;
      if (quiesced && database.isOpen) {
        try {
          await start(snapshotNow: false);
          if (warning == null) await onReady();
        } on Object catch (restartError) {
          _reportFailure('restart', restartError);
        }
      }
    }
    return CatalogReplacementResult(warning: warning);
  }
}
