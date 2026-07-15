import 'dart:io';

import '../data/database_service.dart';
import '../models/catalog_models.dart';
import 'image_storage_service.dart';

/// Coordinates database records with their local image files.
class CatalogService {
  CatalogService({required this.database, required this.images});
  final DatabaseService database;
  final ImageStorageService images;

  Future<List<CatalogRecord>> listRecords() => database.listRecords();
  Future<CatalogRecord?> findByIsbn(String isbn) => database.findByIsbn(isbn);
  Future<List<String>> allTags() => database.allTags();
  Future<List<String>> suggestions(String field, String text) =>
      database.suggestions(field, text);

  Future<CatalogRecord> save(CatalogRecord draft) async {
    var record = draft;
    // A remote cover is downloaded once during save. Afterwards display is entirely local.
    if (record.images.isEmpty && record.work.remoteCoverUrl.trim().isNotEmpty) {
      try {
        final downloaded = await images.downloadRemoteCover(
          work: record.work,
          remoteUrl: record.work.remoteCoverUrl,
        );
        record = record.copyWith(images: [downloaded]);
      } on Exception {
        // Network images are optional; saved URL remains provenance for later retry.
      }
    }
    return database.saveRecord(record);
  }

  Future<void> delete(CatalogRecord record) async {
    for (final image in record.images) {
      await images.deleteImage(image);
    }
    if (record.work.id != null) await database.deleteRecord(record.work.id!);
  }

  Future<List<File>> listBackups() async {
    final folder = Directory(
      '${File(database.databasePath).parent.path}${Platform.pathSeparator}backups',
    );
    if (!await folder.exists()) return const [];
    final files = await folder
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.backup.db'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }
}
