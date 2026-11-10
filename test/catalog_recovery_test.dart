import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/catalog_bundle_service.dart';
import 'package:realmwise/services/catalog_recovery.dart';

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
