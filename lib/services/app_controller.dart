import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database_service.dart';
import 'backup_service.dart';
import 'catalog_service.dart';
import 'external_catalog_service.dart';
import 'image_storage_service.dart';

/// Application session state: selected database, theme preference, and services.
class AppController extends ChangeNotifier {
  AppController()
      : database = DatabaseService(),
        _http = http.Client(),
        backups = BackupService();

  final DatabaseService database;
  final BackupService backups;
  late final ImageStorageService imageStorage = ImageStorageService(_http);
  late final CatalogService catalog = CatalogService(
    database: database,
    images: imageStorage,
  );
  late final ExternalCatalogService lookup = ExternalCatalogService(_http);
  final http.Client _http;

  bool loading = true;
  String? error;
  String seedName = 'Dragon red';

  bool get isOpen => database.isOpen;
  String? get activeDatabasePath => isOpen ? database.databasePath : null;

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('last_database_path');
      if (saved != null && await File(saved).exists()) {
        await openDatabase(saved, remember: false);
      } else {
        await createDatabase('my_rpg_catalog', remember: false);
      }
    } catch (exception) {
      error = exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> createDatabase(
    String requestedName, {
    bool remember = true,
  }) async {
    final documents = await getApplicationDocumentsDirectory();
    final safe = requestedName.trim().replaceAll(
          RegExp(r'[^A-Za-z0-9_-]+'),
          '_',
        );
    if (safe.isEmpty) throw ArgumentError('Enter a database name.');
    await openDatabase(
      path.join(documents.path, '$safe.db'),
      remember: remember,
    );
  }

  Future<void> openDatabase(String databasePath, {bool remember = true}) async {
    error = null;
    await backups.stop();
    await database.open(databasePath);
    final imageFolder = await database.getSetting('image_folder');
    await imageStorage.initialize(imageFolder);
    seedName = await database.getSetting('theme_seed') ?? 'Dragon red';
    await backups.start(
      databasePath: database.databasePath,
      database: database.databaseHandle,
    );
    if (remember) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_database_path', database.databasePath);
    }
    notifyListeners();
  }

  Future<void> closeDatabase() async {
    await backups.stop();
    await database.close();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('last_database_path');
    notifyListeners();
  }

  Future<void> restoreFromBackup(String backupFile) async {
    final documents = await getApplicationDocumentsDirectory();
    final name = 'restored_${DateTime.now().millisecondsSinceEpoch}.db';
    final target = path.join(documents.path, name);
    await File(backupFile).copy(target);
    await openDatabase(target);
  }

  Future<void> setImageFolder(String folder) async {
    await imageStorage.initialize(folder);
    await database.setSetting('image_folder', imageStorage.rootPath);
    notifyListeners();
  }

  Future<void> setTheme(String name) async {
    seedName = name;
    await database.setSetting('theme_seed', name);
    notifyListeners();
  }

  Future<void> saveCatalogIcon({required String tier, required String sectionName, required String sourcePath, double alignmentX = 0, double alignmentY = 0, double zoom = 1}) async {
    final old = await database.getCatalogIcon(tier, sectionName);
    final local = await imageStorage.importCatalogIcon(sourcePath: sourcePath, tier: tier, sectionName: sectionName);
    try {
      await database.upsertCatalogIcon(CatalogIconMapping(tier: tier, sectionName: sectionName, localPath: local, alignmentX: alignmentX, alignmentY: alignmentY, zoom: zoom));
    } catch (_) { await _deleteManagedIcon(local); rethrow; }
    if (old != null && old.localPath != local) await _deleteManagedIcon(old.localPath);
  }

  Future<void> removeCatalogIcon(String tier, String sectionName) async {
    final old = await database.getCatalogIcon(tier, sectionName);
    await database.removeCatalogIcon(tier, sectionName);
    if (old != null) await _deleteManagedIcon(old.localPath);
  }

  Future<void> _deleteManagedIcon(String filePath) async {
    try {
      final root = path.normalize(imageStorage.rootPath);
      final target = path.normalize(filePath);
      if (!path.isWithin(root, target)) return;
      final mappings = await database.listCatalogIcons();
      if (mappings.any((m) => path.normalize(m.localPath) == target)) return;
      final file = File(target);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<String> rpgGeekKey() async =>
      await database.getSetting('rpggeek_api_key') ?? '';
  Future<void> setRpgGeekKey(String key) =>
      database.setSetting('rpggeek_api_key', key.trim());

  @override
  void dispose() {
    unawaited(backups.stop());
    unawaited(database.close());
    _http.close();
    super.dispose();
  }
}
