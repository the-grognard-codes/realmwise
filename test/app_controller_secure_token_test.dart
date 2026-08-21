import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:realmwise/services/secure_storage_service.dart';

class _MemoryTokenStorage implements TokenStorage {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migrates legacy token and removes SQLite value', () async {
    final folder = await Directory.systemTemp.createTemp('rpg_token_');
    PathProviderPlatform.instance = _FakePathProvider(folder.path);
    final dbPath = '${folder.path}${Platform.pathSeparator}one.db';
    final seed = DatabaseService();
    await seed.open(dbPath);
    await seed.setSetting('rpggeek_api_key', ' legacy-token ');
    await seed.close();
    final backupFolder = Directory(
      '${folder.path}${Platform.pathSeparator}backups',
    )..createSync(recursive: true);
    await File(
      dbPath,
    ).copy('${backupFolder.path}${Platform.pathSeparator}legacy.backup.db');
    File(
      '${backupFolder.path}${Platform.pathSeparator}corrupt.backup.db',
    ).writeAsBytesSync([0, 1, 2, 3, 4]);
    final storage = _MemoryTokenStorage();
    final controller = AppController(tokenStorage: storage);
    await controller.openDatabase(dbPath, remember: false);

    expect(await controller.rpgGeekKey(), 'legacy-token');
    expect(await controller.database.getSetting('rpggeek_api_key'), isNull);
    expect(storage.values.values, contains('legacy-token'));
    final backups = Directory('${folder.path}${Platform.pathSeparator}backups');
    final backupFiles = await backups
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    for (final file in backupFiles) {
      final bytes = await file.readAsBytes();
      expect(String.fromCharCodes(bytes), isNot(contains('legacy-token')));
    }

    await controller.database.close();
    controller.dispose();
    await folder.delete(recursive: true);
  });

  test('stable identity survives catalog file rename', () async {
    final folder = await Directory.systemTemp.createTemp('rpg_token_rename_');
    PathProviderPlatform.instance = _FakePathProvider(folder.path);
    final oldPath = '${folder.path}${Platform.pathSeparator}old.db';
    final newPath = '${folder.path}${Platform.pathSeparator}renamed.db';
    final storage = _MemoryTokenStorage();
    final controller = AppController(tokenStorage: storage);
    await controller.openDatabase(oldPath, remember: false);
    await controller.setRpgGeekKey('rename-token');
    await controller.backups.stop();
    await controller.database.close();
    File(oldPath).renameSync(newPath);
    await controller.openDatabase(newPath, remember: false);
    expect(await controller.rpgGeekKey(), 'rename-token');
    await controller.database.close();
    controller.dispose();
    await folder.delete(recursive: true);
  });

  test(
    'failed image storage initialization closes database and can recover',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'realmwise_storage_recovery_',
      );
      PathProviderPlatform.instance = _FakePathProvider(folder.path);
      final invalidImageRoot = File(
        '${folder.path}${Platform.pathSeparator}not-a-directory',
      )..writeAsStringSync('occupied');
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = AppController(
        imageRootPathOverride: invalidImageRoot.path,
        tokenStorage: _MemoryTokenStorage(),
      );
      await controller.initialize();
      expect(controller.isOpen, isFalse);
      expect(controller.activeDatabasePath, isNull);

      await invalidImageRoot.delete();
      final dbPath = '${folder.path}${Platform.pathSeparator}catalog.db';
      await controller.openDatabase(dbPath, remember: false);
      expect(controller.isOpen, isTrue);

      await controller.closeDatabase();
      controller.dispose();
      await folder.delete(recursive: true);
    },
  );

  test(
    'initialize opens legacy default database when Realmwise default is absent',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'realmwise_default_',
      );
      PathProviderPlatform.instance = _FakePathProvider(folder.path);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final legacyPath =
          '${folder.path}${Platform.pathSeparator}my_rpg_catalog.db';
      final seed = DatabaseService();
      await seed.open(legacyPath);
      await seed.close();
      final controller = AppController(tokenStorage: _MemoryTokenStorage());
      await controller.initialize();
      expect(controller.activeDatabasePath, legacyPath);
      await controller.closeDatabase();
      controller.dispose();
      await folder.delete(recursive: true);
    },
  );

  test('secure token round trips and is namespaced per database', () async {
    final folder = await Directory.systemTemp.createTemp(
      'rpg_token_roundtrip_',
    );
    PathProviderPlatform.instance = _FakePathProvider(folder.path);
    final storage = _MemoryTokenStorage();
    final controller = AppController(tokenStorage: storage);
    final one = '${folder.path}${Platform.pathSeparator}one.db';
    final two = '${folder.path}${Platform.pathSeparator}two.db';
    await controller.openDatabase(one, remember: false);
    await controller.setRpgGeekKey(' token-one ');
    expect(await controller.rpgGeekKey(), 'token-one');
    await controller.openDatabase(two, remember: false);
    expect(await controller.rpgGeekKey(), '');
    await controller.setRpgGeekKey('token-two');
    expect(storage.values.length, 2);
    await controller.database.close();
    controller.dispose();
    await folder.delete(recursive: true);
  });
}
