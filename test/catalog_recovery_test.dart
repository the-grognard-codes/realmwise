import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/catalog_bundle_service.dart';
import 'package:realmwise/services/catalog_recovery.dart';
import 'package:realmwise/services/diagnostic_logging.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late DatabaseService database;
  late DateTime now;
  late CatalogRecovery recovery;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalog_recovery_');
    database = DatabaseService();
    await database.open(p.join(dir.path, 'catalog.db'));
    await database.databaseHandle.insert('works', {'title': 'Original'});
    now = DateTime.utc(2026);
    recovery = CatalogRecovery(database: database, clock: () => now);
  });
  tearDown(() async {
    await recovery.stop();
    await database.close();
    await dir.delete(recursive: true);
  });

  test('routine retention cannot trim protective snapshots', () async {
    final bundle = p.join(dir.path, 'import.realmwise');
    await CatalogBundleService().exportBundle(
      database: database,
      outputPath: bundle,
    );
    await recovery.replaceCatalog(bundle, bundle: true);
    final protective = <RestorePoint>[(await recovery.restorePoints()).single];
    for (final kind in [
      SnapshotKind.preDownload,
      SnapshotKind.preRemoteOverwrite,
      SnapshotKind.manual,
    ]) {
      protective.add(await recovery.snapshot(kind));
    }
    for (var i = 0; i < 15; i++) {
      now = now.add(const Duration(minutes: 10));
      await recovery.snapshot(SnapshotKind.routine);
    }
    final points = await recovery.restorePoints();
    expect(
      points.where((point) => point.kind == SnapshotKind.routine),
      hasLength(12),
    );
    for (final point in protective) {
      expect(await File(point.path).exists(), isTrue);
    }
    expect(points.first.timestamp.isAfter(points.last.timestamp), isTrue);
    for (var i = 0; i < 6; i++) {
      now = now.add(const Duration(minutes: 1));
      await recovery.snapshot(SnapshotKind.preImport);
    }
    expect(
      (await recovery.restorePoints()).where(
        (point) => point.kind == SnapshotKind.preImport,
      ),
      hasLength(5),
    );
    expect(await File(protective[1].path).exists(), isTrue);
  });

  test(
    'listing and retention isolate catalogs with a shared filename prefix',
    () async {
      final folder = Directory(p.join(dir.path, 'backups'));
      await folder.create();
      final other = File(
        p.join(folder.path, 'catalog_old_2025-01-01T12-00-00-000.backup.db'),
      );
      await other.writeAsBytes([1]);
      await File(
        p.join(folder.path, 'catalog_old_manual-1700000000000000.backup.db'),
      ).writeAsBytes([1]);
      for (var i = 0; i < 14; i++) {
        await recovery.snapshot(SnapshotKind.routine);
      }
      final points = await recovery.restorePoints();
      expect(points, hasLength(12));
      expect(
        points.any((point) => point.name.startsWith('catalog_old_')),
        isFalse,
      );
      expect(await other.exists(), isTrue);
    },
  );

  test(
    'kind markers in the catalog basename do not affect snapshot kind',
    () async {
      await database.close();
      await database.open(p.join(dir.path, 'catalog_manual-edition.db'));
      for (var i = 0; i < 14; i++) {
        await recovery.snapshot(SnapshotKind.routine);
      }
      final points = await recovery.restorePoints();
      expect(points, hasLength(12));
      expect(
        points.every((point) => point.kind == SnapshotKind.routine),
        isTrue,
      );
    },
  );

  test('legacy database and bundle names retain their kinds', () async {
    final folder = Directory(p.join(dir.path, 'backups'));
    await folder.create();
    for (final name in [
      'catalog_2025-01-01T12-00-00-000.backup.db',
      'catalog_pre-import-1700000000000000.backup.db',
      'catalog_pre-remote-overwrite-1700000000000001.realmwise',
    ]) {
      await File(p.join(folder.path, name)).writeAsBytes([1]);
    }
    final points = await recovery.restorePoints();
    expect(points.map((point) => point.kind).toSet(), {
      SnapshotKind.routine,
      SnapshotKind.preImport,
      SnapshotKind.preRemoteOverwrite,
    });
  });

  test(
    'snapshots scrub secrets without changing the active database',
    () async {
      await database.setSetting('rpggeek_api_key', 'legacy-secret');
      await database.setSetting('cloud_sync_token:legacy', 'oauth-secret');
      final snapshot = await recovery.snapshot(SnapshotKind.manual);
      final bytes = String.fromCharCodes(
        await File(snapshot.path).readAsBytes(),
      );
      expect(bytes, isNot(contains('legacy-secret')));
      expect(bytes, isNot(contains('oauth-secret')));
      expect(await database.getSetting('rpggeek_api_key'), 'legacy-secret');
    },
  );

  Future<String> replacement() async {
    final other = DatabaseService();
    final file = p.join(dir.path, 'replacement.db');
    await other.open(file);
    await other.databaseHandle.insert('works', {'title': 'Replacement'});
    await other.close();
    return file;
  }

  test(
    'remote overwrite restore points preserve bundled personal images',
    () async {
      final image = File(p.join(dir.path, 'personal.jpg'));
      await image.writeAsBytes([1, 2, 3, 4]);
      await database.saveRecord(
        CatalogRecord(
          work: BookWork(title: 'Illustrated'),
          images: [BookImage(localPath: image.path, isCover: true)],
        ),
      );
      final bundle = p.join(dir.path, 'remote.realmwise');
      final bundles = CatalogBundleService();
      await bundles.exportBundle(
        database: database,
        outputPath: bundle,
        includePersonalImages: true,
      );
      final point = await recovery.snapshot(
        SnapshotKind.preRemoteOverwrite,
        bundleBytes: await File(bundle).readAsBytes(),
      );
      expect((await bundles.validateBundle(point.path)).assets, hasLength(1));
      expect(
        (await recovery.restorePoints()).any(
          (entry) => entry.path == point.path,
        ),
        isTrue,
      );
    },
  );

  test(
    'replacement waits for sync before taking snapshot or closing',
    () async {
      final entered = Completer<void>(), sync = Completer<void>();
      recovery = CatalogRecovery(
        database: database,
        waitForSync: () async {
          entered.complete();
          await sync.future;
        },
      );
      final active = database.databasePath;
      final operation = recovery.replaceCatalog(await replacement());
      await entered.future;
      expect(database.isOpen, isTrue);
      expect(await recovery.restorePoints(), isEmpty);
      await database.databaseHandle.insert('works', {
        'title': 'Last sync edit',
      });
      sync.complete();
      await operation;
      expect(database.databasePath, active);
      expect(
        (await database.databaseHandle.query('works')).single['title'],
        'Replacement',
      );
      final point = (await recovery.restorePoints()).single;
      final snapshot = DatabaseService();
      await snapshot.open(point.path);
      expect(
        (await snapshot.databaseHandle.query('works'))
            .map((row) => row['title']),
        contains('Last sync edit'),
      );
      await snapshot.close();
    },
  );

  for (final failure in [
    'copy',
    'rename-original',
    'rename-replacement',
    'reopen',
    'rehydrate',
  ]) {
    test('$failure failure rolls back and reopens the original', () async {
      var injected = false;
      final active = database.databasePath;
      final source = await replacement();
      recovery = CatalogRecovery(
        database: database,
        copyFile: (file, target) async {
          if (failure == 'copy') throw const FileSystemException('copy failed');
          return file.copy(target);
        },
        renameFile: (file, target) async {
          if ((failure == 'rename-original' && file.path == active) ||
              (failure == 'rename-replacement' && target == active))
            throw const FileSystemException('rename failed');
          return file.rename(target);
        },
        reopen: (file) async {
          if (failure == 'reopen' && !injected) {
            injected = true;
            throw StateError('reopen failed');
          }
          await database.open(file);
        },
        rehydrate: () async {
          if (failure == 'rehydrate') throw StateError('rehydrate failed');
          return false;
        },
      );
      await expectLater(
        recovery.replaceCatalog(source),
        throwsA(isA<Object>()),
      );
      expect(database.isOpen, isTrue);
      expect(database.databasePath, active);
      expect(
        (await database.databaseHandle.query('works')).single['title'],
        'Original',
      );
      expect(
        dir.listSync().where(
          (file) =>
              file.path.contains('.replace-') ||
              file.path.contains('.rollback-'),
        ),
        isEmpty,
      );
    });
  }

  for (final renameBlocked in [false, true]) {
    test(
      'replacement delete failure ${renameBlocked ? "reopens replacement" : "retries original rename"}',
      () async {
        final failure = StateError('primary rehydrate failure');
        final active = database.databasePath;
        final sourceDatabase = DatabaseService();
        await sourceDatabase.open(await replacement());
        final image = File(p.join(dir.path, 'cover.png'));
        await image.writeAsBytes([1, 2, 3]);
        final work = (await sourceDatabase.listRecords()).single.work;
        await sourceDatabase.saveRecord(
          CatalogRecord(
            work: work,
            images: [BookImage(localPath: image.path, isCover: true)],
          ),
        );
        final source = p.join(dir.path, 'replacement.realmwise');
        await CatalogBundleService().exportBundle(
          database: sourceDatabase,
          outputPath: source,
          includePersonalImages: true,
        );
        await sourceDatabase.close();
        final imageRoot = p.join(dir.path, 'restored-images');
        final events = _DiagnosticCapture();
        final previousLogger = DiagnosticDiagnostics.logger;
        DiagnosticDiagnostics.logger = events;
        addTearDown(() => DiagnosticDiagnostics.logger = previousLogger);
        var ready = 0;
        recovery = CatalogRecovery(
          database: database,
          deleteFile: (file) async {
            if (file.path == active)
              throw const FileSystemException('replacement delete blocked');
            await file.delete();
          },
          renameFile: (file, target) async {
            if (renameBlocked && file.path.contains('.rollback-')) {
              throw const FileSystemException('original rename blocked');
            }
            return file.rename(target);
          },
          rehydrate: () async => throw failure,
          onReady: () async {
            ready++;
          },
        );
        final replacing = recovery.replaceCatalog(
          source,
          bundle: true,
          imageRootPath: imageRoot,
        );
        if (renameBlocked) {
          final result = await replacing;
          expect(result.needsAcknowledgement, isTrue);
          expect(result.warning!.originalPath, contains('.rollback-'));
          // A new service instance represents reopening after process exit.
          final restarted = CatalogRecovery(database: database);
          await restarted.loadWarning();
          expect(restarted.warning!.originalPath, result.warning!.originalPath);
          final later = await restarted.replaceCatalog(
            source,
            bundle: true,
            imageRootPath: imageRoot,
          );
          expect(later.needsAcknowledgement, isFalse);
          expect(later.warning, isNull);
          await restarted.stop();
          await restarted.acknowledgeWarning();
          await restarted.loadWarning();
          expect(restarted.warning, isNull);
        } else {
          await expectLater(replacing, throwsA(same(failure)));
          expect(recovery.warning, isNull);
        }
        expect(database.isOpen, isTrue);
        expect(database.databasePath, active);
        expect(
          (await database.databaseHandle.query('works')).single['title'],
          renameBlocked ? 'Replacement' : 'Original',
        );
        expect(ready, renameBlocked ? 0 : 1);
        expect(events.events, contains('recovery.rollback.error'));
        final originals = dir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.contains('.rollback-'))
            .toList();
        if (renameBlocked) {
          final original = await databaseFactory.openDatabase(
            originals.single.path,
          );
          try {
            expect((await original.query('works')).single['title'], 'Original');
          } finally {
            await original.close();
          }
        } else {
          expect(originals, isEmpty);
        }
      },
    );
  }

  test(
    'rollback failure preserves the original exception and rollback file',
    () async {
      final original = StateError('primary reopen failure');
      final events = _DiagnosticCapture();
      final previousLogger = DiagnosticDiagnostics.logger;
      DiagnosticDiagnostics.logger = events;
      addTearDown(() => DiagnosticDiagnostics.logger = previousLogger);
      final active = database.databasePath;
      var attempts = 0;
      recovery = CatalogRecovery(
        database: database,
        reopen: (_) async {
          attempts++;
          if (attempts == 1) throw original;
          throw const FileSystemException('secondary rollback reopen failure');
        },
      );
      await expectLater(
        recovery.replaceCatalog(await replacement()),
        throwsA(same(original)),
      );
      expect(recovery.isReplacing, isFalse);
      await database.open(active);
      expect(
        (await database.databaseHandle.query('works')).single['title'],
        'Original',
      );
    },
  );

  for (final target in ['.replace-', '.rollback-']) {
    test(
      'committed import tolerates $target cleanup failure and retries later',
      () async {
        var blocked = true, ready = 0;
        final failures = <String>{};
        final events = _DiagnosticCapture();
        final previousLogger = DiagnosticDiagnostics.logger;
        DiagnosticDiagnostics.logger = events;
        addTearDown(() => DiagnosticDiagnostics.logger = previousLogger);
        recovery = CatalogRecovery(
          database: database,
          deleteFile: (file) async {
            if (blocked && file.path.contains(target)) {
              failures.add(file.path);
              throw const FileSystemException('injected cleanup lock');
            }
            await file.delete();
          },
          onReady: () async {
            ready++;
          },
        );
        final result = await recovery.replaceCatalog(await replacement());
        expect(result.needsAcknowledgement, isFalse);
        expect(recovery.warning, isNull);
        expect(ready, 1);
        expect((await database.listRecords()).single.work.title, 'Replacement');
        expect(events.events, contains('recovery.cleanup.error'));
        expect(failures, isNotEmpty);
        blocked = false;
        await recovery.snapshot(SnapshotKind.manual);
        for (final file in failures) {
          expect(await File(file).exists(), isFalse);
        }
      },
    );
  }

  test(
    'successful replacement cleans discarded original and staged sidecars',
    () async {
      await database.databaseHandle.rawQuery('PRAGMA journal_mode=WAL');
      await database.databaseHandle.insert('works', {
        'title': 'Committed in WAL',
      });
      final active = database.databasePath;
      recovery = CatalogRecovery(
        database: database,
        copyFile: (file, target) async {
          // Simulate sidecars left behind by a previous process after close.
          for (final suffix in ['-wal', '-shm', '-journal']) {
            await File('$active$suffix').writeAsBytes([]);
            await File('${file.path}$suffix').writeAsBytes([1, 2, 3]);
          }
          return file.copy(target);
        },
      );
      await recovery.replaceCatalog(await replacement());
      expect(
        (await database.databaseHandle.query('works')).single['title'],
        'Replacement',
      );
      expect(
        dir.listSync().where((file) => file.path.contains('.replace-')),
        isEmpty,
      );
      for (final suffix in ['-wal', '-shm', '-journal']) {
        expect(await File('$active$suffix').exists(), isFalse);
      }
    },
  );

  test(
    'busy truncate checkpoint refuses replacement without closing the original',
    () async {
      await database.databaseHandle.rawQuery('PRAGMA journal_mode=WAL');
      await database.databaseHandle.execute('PRAGMA busy_timeout=0');
      await database.databaseHandle.insert('works', {
        'title': 'Committed WAL row',
      });
      final reader = await databaseFactory.openDatabase(
        database.databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await reader.execute('BEGIN');
        await reader.rawQuery('SELECT * FROM works');
        expect(
          (await database.databaseHandle.rawQuery(
            'PRAGMA wal_checkpoint(FULL)',
          )).single['busy'],
          0,
        );
        final originalHandle = database.databaseHandle;
        await expectLater(
          recovery.replaceCatalog(await replacement()),
          throwsStateError,
        );
        expect(database.isOpen, isTrue);
        expect(database.databaseHandle, same(originalHandle));
        expect(
          (await database.databaseHandle.query('works'))
              .map((row) => row['title']),
          contains('Committed WAL row'),
        );
      } finally {
        await reader.execute('ROLLBACK');
        await reader.close();
      }
    },
  );

  test('copy failure preserves committed WAL written by another connection after close', () async {
    final active = database.databasePath;
    await database.databaseHandle.rawQuery('PRAGMA journal_mode=WAL');
    final other = await databaseFactory.openDatabase(
      active,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final failure = StateError('copy failed after concurrent commit');
    recovery = CatalogRecovery(
      database: database,
      copyFile: (_, _) async {
        await other.insert('works', {'title': 'Committed after close'});
        throw failure;
      },
    );
    try {
      await expectLater(
        recovery.replaceCatalog(await replacement()),
        throwsA(same(failure)),
      );
      expect(
        (await database.databaseHandle.query('works'))
            .map((row) => row['title']),
        containsAll(['Original', 'Committed after close']),
      );
    } finally {
      await other.close();
    }
  });

  test(
    'remaining original sidecars move back with the original on rollback',
    () async {
      final active = database.databasePath;
      final failure = StateError('install failed');
      var restoredSidecars = false;
      recovery = CatalogRecovery(
        database: database,
        copyFile: (file, target) async {
          for (final suffix in ['-wal', '-shm', '-journal']) {
            await File('$active$suffix').writeAsBytes([]);
          }
          return file.copy(target);
        },
        renameFile: (file, target) async {
          if (target == active) throw failure;
          return file.rename(target);
        },
        reopen: (file) async {
          expect(await File('$file-wal').exists(), isFalse);
          for (final suffix in ['-shm', '-journal']) {
            expect(await File('$file$suffix').exists(), isTrue);
          }
          restoredSidecars = true;
          await database.open(file);
        },
      );
      await expectLater(
        recovery.replaceCatalog(await replacement()),
        throwsA(same(failure)),
      );
      expect(restoredSidecars, isTrue);
      expect(
        (await database.databaseHandle.query('works')).single['title'],
        'Original',
      );
    },
  );

  test(
    'rollback reopens a restored main file even when a sidecar cannot return',
    () async {
      final active = database.databasePath;
      final failure = StateError('replacement install failed');
      var reopened = 0;
      recovery = CatalogRecovery(
        database: database,
        copyFile: (file, target) async {
          await File('$active-shm').writeAsBytes([]);
          return file.copy(target);
        },
        renameFile: (file, target) async {
          if (target == active) {
            // Simulate a handle recreating the destination sidecar during rollback.
            await File('$active-shm').writeAsBytes([]);
            throw failure;
          }
          return file.rename(target);
        },
        reopen: (file) async {
          reopened++;
          await database.open(file);
        },
      );
      await expectLater(
        recovery.replaceCatalog(await replacement()),
        throwsA(same(failure)),
      );
      expect(reopened, 1);
      expect(database.isOpen, isTrue);
      expect(
        (await database.databaseHandle.query('works')).single['title'],
        'Original',
      );
    },
  );

  test(
    'new committed WAL pages refuse replacement before the original moves',
    () async {
      final active = database.databasePath;
      await database.databaseHandle.rawQuery('PRAGMA journal_mode=WAL');
      final other = await databaseFactory.openDatabase(
        active,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      var renames = 0;
      recovery = CatalogRecovery(
        database: database,
        copyFile: (file, target) async {
          await other.insert('works', {'title': 'Concurrent WAL commit'});
          return file.copy(target);
        },
        renameFile: (file, target) async {
          renames++;
          return file.rename(target);
        },
      );
      try {
        await expectLater(
          recovery.replaceCatalog(await replacement()),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('retry'),
            ),
          ),
        );
        expect(renames, 0);
        expect(database.isOpen, isTrue);
        expect(
          (await database.databaseHandle.query('works'))
              .map((row) => row['title']),
          containsAll(['Original', 'Concurrent WAL commit']),
        );
      } finally {
        await other.close();
      }
    },
  );

  test(
    'replacement retries a checkpoint while a short-lived reader finishes',
    () async {
      final source = await replacement();
      await database.databaseHandle.rawQuery('PRAGMA journal_mode=WAL');
      await database.databaseHandle.execute('PRAGMA busy_timeout=0');
      await database.databaseHandle.insert('works', {'title': 'WAL row'});
      final reader = await databaseFactory.openDatabase(
        database.databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await reader.execute('BEGIN');
      await reader.rawQuery('SELECT * FROM works');
      var released = false;
      final releasing = Future<void>.delayed(
        const Duration(milliseconds: 150),
        () async {
          await reader.execute('ROLLBACK');
          await reader.close();
          released = true;
        },
      );
      recovery = CatalogRecovery(
        database: database,
        copyFile: (file, target) async {
          expect(released, isTrue);
          return file.copy(target);
        },
      );
      try {
        await recovery.replaceCatalog(source);
        expect(
          (await database.databaseHandle.query('works')).single['title'],
          'Replacement',
        );
      } finally {
        await releasing;
      }
    },
  );

  test('invalid source is rejected before waiting for sync', () async {
    var waited = false;
    recovery = CatalogRecovery(
      database: database,
      waitForSync: () async {
        waited = true;
      },
    );
    final invalid = File(p.join(dir.path, 'invalid.db'));
    await invalid.writeAsBytes([1, 2, 3]);
    await expectLater(
      recovery.replaceCatalog(invalid.path),
      throwsA(isA<Object>()),
    );
    expect(waited, isFalse);
    expect(database.isOpen, isTrue);
    expect(
      (await database.databaseHandle.query('works')).single['title'],
      'Original',
    );
  });
}

class _DiagnosticCapture extends DiagnosticLogger {
  final events = <String>[];
  @override
  Future<void> log(
    DiagnosticSeverity severity,
    String event, [
    Map<String, Object?> fields = const {},
  ]) async {
    events.add(event);
    expect(fields.keys, contains('errorClass'));
    expect(fields.values, isNot(contains('secondary rollback reopen failure')));
  }
}
