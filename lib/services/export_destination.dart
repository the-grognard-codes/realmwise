import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart' as selector;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'diagnostic_bundle_exporter.dart';
import 'diagnostic_logging.dart';

void _logExportError(
  String event,
  Object error, {
  DiagnosticSeverity severity = DiagnosticSeverity.warning,
}) {
  DiagnosticDiagnostics.emit(severity, event, {
    'errorClass': error.runtimeType.toString(),
  });
}

sealed class ExportResult {
  const ExportResult();
}

final class ExportSaved extends ExportResult {
  const ExportSaved();
}

final class ExportCancelled extends ExportResult {
  const ExportCancelled();
}

final class ExportFailed extends ExportResult {
  const ExportFailed();
  String get message => 'Could not export the file. Please try again.';
}

abstract interface class ExportDestinationAdapter {
  Future<ExportTarget?> chooseDestination({
    required String fileName,
    required String mimeType,
  });
}

abstract class ExportTarget {
  Future<void> save(String temporaryPath);

  /// Releases a newly created destination on failure.
  Future<void> discard() async {}
}

/// Owns the temporary content; producers never write directly to a destination.
class ExportDestination {
  ExportDestination({
    ExportDestinationAdapter? adapter,
    Future<Directory> Function()? temporaryDirectory,
    bool? isAndroid,
  }) : _adapter =
           adapter ??
           ((isAndroid ?? Platform.isAndroid)
               ? const AndroidExportDestinationAdapter()
               : const DesktopExportDestinationAdapter()),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final ExportDestinationAdapter _adapter;
  final Future<Directory> Function() _temporaryDirectory;

  Future<ExportResult> export({
    required String fileName,
    required String mimeType,
    required Future<void> Function(String path) produce,
  }) async {
    ExportTarget? target;
    Directory? staging;
    ExportResult result;
    try {
      target = await _adapter.chooseDestination(
        fileName: fileName,
        mimeType: mimeType,
      );
      if (target == null) return const ExportCancelled();
      final root = await _temporaryDirectory();
      staging = await root.createTemp('realmwise-export-');
      final path = p.join(staging.path, p.basename(fileName));
      await produce(path);
      await target.save(path);
      result = const ExportSaved();
    } on Object catch (error) {
      // Plugin and producer errors can contain credentials or private paths.
      _logExportError(
        'export.error',
        error,
        severity: DiagnosticSeverity.error,
      );
      result = const ExportFailed();
    }
    if (target != null && result is! ExportSaved) {
      try {
        await target.discard();
      } on Object catch (error) {
        // Preserve the safe original result if destination cleanup fails.
        _logExportError('export.destination_cleanup.error', error);
      }
    }
    if (staging != null) {
      try {
        await staging.delete(recursive: true);
      } on Object catch (error) {
        // Cleanup cannot undo a completed save or change its reported result.
        _logExportError('export.staging_cleanup.error', error);
      }
    }
    return result;
  }
}

class AndroidExportDestinationAdapter implements ExportDestinationAdapter {
  const AndroidExportDestinationAdapter({
    this.exporter = const DiagnosticBundleExporter(),
  });

  final DiagnosticBundleExporter exporter;

  @override
  Future<ExportTarget?> chooseDestination({
    required String fileName,
    required String mimeType,
  }) async {
    final uri = await exporter.chooseDestination(
      fileName: fileName,
      mimeType: mimeType,
    );
    return uri == null ? null : _AndroidTarget(exporter, uri);
  }
}

class _AndroidTarget extends ExportTarget {
  _AndroidTarget(this.exporter, this.uri);
  final DiagnosticBundleExporter exporter;
  final String uri;
  @override
  Future<void> save(String temporaryPath) async {
    await exporter.copyFileToDestination(path: temporaryPath, uri: uri);
  }

  @override
  Future<void> discard() => exporter.deleteDestination(uri);
}

typedef ExportSaveDialog = Future<String?> Function({required String fileName});

/// Filesystem operations used by the desktop adapter, injectable for failures.
class ExportFileSystem {
  const ExportFileSystem();

  File file(String path) => File(path);
  Directory directory(String path) => Directory(path);

  Future<void> copyFile(String sourcePath, String destinationPath) async {
    await file(sourcePath).copy(destinationPath);
  }
}

class DesktopExportDestinationAdapter implements ExportDestinationAdapter {
  const DesktopExportDestinationAdapter({
    ExportSaveDialog? saveDialog,
    this.fileSystem = const ExportFileSystem(),
  }) : _saveDialog = saveDialog ?? _showSaveDialog;

  final ExportSaveDialog _saveDialog;
  final ExportFileSystem fileSystem;

  static Future<String?> _showSaveDialog({required String fileName}) async {
    // The path-only API uses the OS dialog title; it has no title parameter.
    final location = await selector.getSaveLocation(suggestedName: fileName);
    return location?.path;
  }

  @override
  Future<ExportTarget?> chooseDestination({
    required String fileName,
    required String mimeType,
  }) async {
    final path = await _saveDialog(fileName: fileName);
    return path == null ? null : _DesktopTarget(path, fileSystem);
  }
}

class _DesktopTarget extends ExportTarget {
  _DesktopTarget(this.path, this.fileSystem);
  final String path;
  final ExportFileSystem fileSystem;
  static final _random = Random.secure();
  static final _activeFiles = <String>{};

  static String _key(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<void> _removePartial(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object catch (error) {
      _logExportError('export.destination_cleanup.error', error);
    }
  }

  Future<void> _removeStalePartials() async {
    final prefix = '${p.basename(path)}.partial-';
    try {
      await for (final entry
          in fileSystem.directory(p.dirname(path)).list(followLinks: false)) {
        if (entry is! File || _activeFiles.contains(_key(entry.path))) continue;
        final name = p.basename(entry.path);
        final matches = Platform.isWindows
            ? name.toLowerCase().startsWith(prefix.toLowerCase())
            : name.startsWith(prefix);
        if (matches) await _removePartial(fileSystem.file(entry.path));
      }
    } on Object catch (error) {
      // Listing or deleting leftovers must not prevent a permitted file write.
      _logExportError('export.destination_cleanup.error', error);
    }
  }

  Future<File> _createPartial() async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final suffix = List.generate(
        16,
        (_) => _random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      final pending = fileSystem.file('$path.partial-$suffix');
      final key = _key(pending.path);
      if (!_activeFiles.add(key)) continue;
      try {
        await pending.create(exclusive: true);
        return pending;
      } on PathExistsException {
        _activeFiles.remove(key);
      } on Object {
        _activeFiles.remove(key);
        rethrow;
      }
    }
    throw const FileSystemException(
      'Could not reserve an export temporary file.',
    );
  }

  @override
  Future<void> save(String temporaryPath) async {
    await _removeStalePartials();
    // A sibling file needs no folder-creation rights and keeps the final rename
    // on the destination filesystem. Never copy directly over an existing file.
    final pending = await _createPartial();
    try {
      await fileSystem.copyFile(temporaryPath, pending.path);
      await pending.rename(path);
    } finally {
      await _removePartial(pending);
      _activeFiles.remove(_key(pending.path));
    }
  }
}
