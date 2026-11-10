import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/database_service.dart';
import '../models/catalog_models.dart';
import 'image_storage_service.dart';
import 'diagnostic_logging.dart';

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

  final Set<CatalogEditSession> _edits = {};

  CatalogEditSession beginEditing(CatalogRecord record) {
    final edit = CatalogEditSession._(this, record);
    _edits.add(edit);
    return edit;
  }

  Future<void> discardEdits() async {
    await Future.wait(_edits.toList().map((edit) => edit.discard()));
  }

  Future<void> cleanupAbandonedEdits() => images.cleanupAbandonedEdits();

  Future<CatalogRecord> save(CatalogRecord draft) async {
    final edit = beginEditing(draft);
    try {
      return await edit.save();
    } finally {
      await edit.discard();
    }
  }

  /// Restores local files omitted from portable bundles while retaining image
  /// metadata and any user-owned local-only images.
  Future<bool> rehydrateMissingImages() async {
    var changed = false;
    for (final record in await database.listRecords()) {
      final restored = <BookImage>[];
      var recordChanged = false;
      for (final image in record.images) {
        final localPath = image.localPath.trim();
        final exists = localPath.isNotEmpty && await File(localPath).exists();
        if (exists) {
          restored.add(image);
          continue;
        }
        if (image.sourceType != ImageSourceType.remoteCache) {
          restored.add(image);
          continue;
        }
        final remoteUrl = image.remoteUrl.trim().isNotEmpty
            ? image.remoteUrl.trim()
            : (image.isCover ? record.work.remoteCoverUrl.trim() : '');
        if (remoteUrl.isEmpty) {
          restored.add(image);
          continue;
        }
        try {
          final downloaded = await images.downloadRemoteCover(
            work: record.work,
            remoteUrl: remoteUrl,
          );
          restored.add(
            downloaded.copyWith(
              remoteUrl: image.remoteUrl.trim().isNotEmpty
                  ? image.remoteUrl
                  : downloaded.remoteUrl,
              caption: image.caption,
              isCover: image.isCover,
              sortOrder: image.sortOrder,
            ),
          );
          recordChanged = true;
        } catch (_) {
          // A network outage must not make restoring the catalog fail.
          restored.add(image);
        }
      }
      if (recordChanged) {
        await database.saveRecord(record.copyWith(images: restored));
        changed = true;
      }
    }
    return changed;
  }

  Future<void> delete(CatalogRecord record) async {
    try {
      for (final image in record.images) {
        await images.deleteImage(image);
      }
      if (record.work.id != null) await database.deleteRecord(record.work.id!);
    } on Object catch (error) {
      DiagnosticDiagnostics.emit(
        DiagnosticSeverity.error,
        'catalog.delete.error',
        {
          'operation': 'delete',
          'outcome': 'failed',
          'errorClass': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
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

/// Visit-scoped draft. Only save publishes files or changes stored rows.
class CatalogEditSession {
  CatalogEditSession._(this.catalog, CatalogRecord record)
    : _record = record.copyWith(
        copies: List.unmodifiable(record.copies),
        images: List.unmodifiable(record.images),
      ),
      _generation = catalog.database.catalogGeneration;
  final CatalogService catalog;
  final int _generation;
  CatalogRecord _record;
  CatalogRecord get record => _record;
  Future<Directory>? _staging;
  Future<void> _tail = Future.value();
  bool _closed = false;

  void _check() {
    if (_closed) throw StateError('This edit session has ended.');
    if (!catalog.database.isOpen ||
        catalog.database.catalogGeneration != _generation) {
      throw StateError('The catalog changed; reopen the record before saving.');
    }
  }

  void update(CatalogRecord value) {
    _check();
    if (value.work.id != _record.work.id)
      throw ArgumentError('An edit session belongs to one work.');
    _record = value.copyWith(
      copies: List.unmodifiable(value.copies),
      images: List.unmodifiable(value.images),
    );
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _tail.then((_) {
      _check();
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Directory> _directory() =>
      _staging ??= catalog.images.createEditStaging();

  Future<void> addFile(String sourcePath, {required String label}) =>
      _run(() async {
        final image = await catalog.images.stageFile(
          directory: await _directory(),
          work: record.work,
          sourcePath: sourcePath,
          label: label,
          cover: record.images.isEmpty,
        );
        _check();
        update(record.copyWith(images: [...record.images, image]));
      });

  Future<void> _downloadCover() async {
    if (record.images.isNotEmpty || record.work.remoteCoverUrl.trim().isEmpty)
      return;
    final image = await catalog.images.stageRemoteCover(
      directory: await _directory(),
      work: record.work,
      remoteUrl: record.work.remoteCoverUrl,
    );
    _check();
    if (record.images.isEmpty) update(record.copyWith(images: [image]));
  }

  Future<void> addRemoteCover() => _run(_downloadCover);

  void setCover(int index) {
    _check();
    if (index < 0 || index >= record.images.length)
      throw RangeError.index(index, record.images);
    update(
      record.copyWith(
        images: List.generate(
          record.images.length,
          (i) => record.images[i].copyWith(isCover: i == index),
        ),
      ),
    );
  }

  void removeImage(int index) {
    _check();
    final images = [...record.images]..removeAt(index);
    update(record.copyWith(images: normalizeBookImages(images)));
  }

  void reorderImage(int oldIndex, int newIndex) {
    _check();
    final images = [...record.images];
    final moved = images.removeAt(oldIndex);
    images.insert(newIndex, moved);
    update(record.copyWith(images: normalizeBookImages(images)));
  }

  Future<CatalogRecord> save() => _run(
    () => catalog.database.withCatalogFiles(() async {
      _check();
      final originals = record.work.id == null
          ? const <BookImage>[]
          : (await catalog.database.getRecord(record.work.id!)).images;
      if (record.images.isEmpty &&
          record.work.remoteCoverUrl.trim().isNotEmpty) {
        try {
          await _downloadCover();
        } catch (error) {
          _check(); /* Cover downloads are optional; retain the source URL. */
        }
      }
      final published = <String, String>{};
      late CatalogRecord saved;
      try {
        final images = <BookImage>[];
        for (var image in normalizeBookImages(record.images)) {
          final staging = _staging == null ? null : await _staging!;
          var staged =
              staging != null && p.isWithin(staging.path, image.localPath);
          final original = originals
              .where((old) => old.localPath == image.localPath)
              .firstOrNull;
          if (!staged &&
              original != null &&
              original.isCover != image.isCover &&
              await File(image.localPath).exists()) {
            final copy = await catalog.images.stageFile(
              directory: await _directory(),
              work: record.work,
              sourcePath: image.localPath,
              label: image.caption,
              cover: image.isCover,
            );
            image = image.copyWith(localPath: copy.localPath);
            staged = true;
          }
          if (staged) {
            final stagedPath = image.localPath;
            image = await catalog.images.publishStagedImage(image, record.work);
            published[image.localPath] = stagedPath;
          }
          images.add(image);
        }
        _check();
        saved = await catalog.database.saveRecord(
          record.copyWith(images: images),
        );
      } catch (error) {
        DiagnosticDiagnostics.emit(
          DiagnosticSeverity.error,
          'catalog.save.error',
          {
            'operation': 'save',
            'outcome': 'failed',
            'errorClass': error.runtimeType.toString(),
          },
        );
        for (final file in published.entries) {
          if (await File(file.key).exists())
            await File(file.key).rename(file.value);
        }
        rethrow;
      }
      _record = saved;
      _closed = true;
      // A committed row must never point to a removed file. Clean old files only
      // after the transaction, and retain files still referenced by another work.
      final retained = saved.images.map((image) => image.localPath).toSet();
      for (final original in originals) {
        if (original.localPath.isEmpty || retained.contains(original.localPath))
          continue;
        try {
          if (catalog.images.isManagedImage(original.localPath) &&
              !await catalog.database.referencesImage(original.localPath)) {
            await catalog.images.deleteImage(original);
          }
        } on Object catch (error) {
          _cleanupFailure(error);
        }
      }
      await _cleanup();
      catalog._edits.remove(this);
      DiagnosticDiagnostics.emit(
        DiagnosticSeverity.debug,
        'catalog.save.success',
        const {'operation': 'save', 'outcome': 'success'},
      );
      return saved;
    }),
  );

  Future<void> discard() async {
    _closed = true;
    await _tail;
    catalog._edits.remove(this);
    await _cleanup();
  }

  Future<void> _cleanup() async {
    if (_staging == null) return;
    try {
      final folder = await _staging!;
      if (await folder.exists()) await folder.delete(recursive: true);
    } on Object catch (error) {
      _cleanupFailure(error);
    }
  }

  void _cleanupFailure(Object error) => DiagnosticDiagnostics.emit(
    DiagnosticSeverity.warning,
    'catalog.edit.cleanup.error',
    {'operation': 'edit_cleanup', 'errorClass': error.runtimeType.toString()},
  );
}
