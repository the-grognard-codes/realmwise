import 'dart:io';

import 'package:file_selector/file_selector.dart' as selector;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'diagnostic_bundle_exporter.dart';
import 'diagnostic_logging.dart';

void _logExportError(String event, Object error) {
  DiagnosticDiagnostics.emit(DiagnosticSeverity.warning, event, {
    'errorClass': error.runtimeType.toString(),
  });
}

sealed class ExportResult {
  const ExportResult();
}

final class ExportSaved extends ExportResult {
  const ExportSaved(this.locationDescription);
  final String locationDescription;
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
  String get locationDescription;

  /// Returns false if saving is cancelled after production.
  Future<bool> save(String temporaryPath);

  /// Releases a newly created destination on failure or cancellation.
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
      result = await target.save(path)
          ? ExportSaved(target.locationDescription)
          : const ExportCancelled();
    } on Object catch (error) {
      // Plugin and producer errors can contain credentials or private paths.
      _logExportError('export.error', error);
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
    return uri == null ? null : _AndroidTarget(exporter, uri, fileName);
  }
}

class _AndroidTarget extends ExportTarget {
  _AndroidTarget(this.exporter, this.uri, this.locationDescription);
  final DiagnosticBundleExporter exporter;
  final String uri;
  @override
  final String locationDescription;

  @override
  Future<bool> save(String temporaryPath) async {
    await exporter.copyFileToDestination(path: temporaryPath, uri: uri);
    return true;
  }

  @override
  Future<void> discard() => exporter.deleteDestination(uri);
}

typedef ExportSaveDialog = Future<String?> Function({required String fileName});
typedef ExportFileCopy = Future<void> Function(
  String sourcePath,
  String destinationPath,
);

class DesktopExportDestinationAdapter implements ExportDestinationAdapter {
  const DesktopExportDestinationAdapter({
    ExportSaveDialog? saveDialog,
    ExportFileCopy? copyFile,
  }) : _saveDialog = saveDialog ?? _showSaveDialog,
       _copyFile = copyFile ?? _copy;

  final ExportSaveDialog _saveDialog;
  final ExportFileCopy _copyFile;

  static Future<void> _copy(String sourcePath, String destinationPath) async {
    await File(sourcePath).copy(destinationPath);
  }

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
    return path == null ? null : _DesktopTarget(path, _copyFile);
  }
}

class _DesktopTarget extends ExportTarget {
  _DesktopTarget(this.path, this.copyFile);
  final String path;
  final ExportFileCopy copyFile;
  @override
  String get locationDescription => p.basename(path);

  @override
  Future<bool> save(String temporaryPath) async {
    // Stage on the destination filesystem so a partial copy cannot damage an
    // existing export and the final rename does not cross filesystem boundaries.
    final staging = await Directory(p.dirname(path))
        .createTemp('.realmwise-export-');
    try {
      final pending = p.join(staging.path, p.basename(path));
      await copyFile(temporaryPath, pending);
      await File(pending).rename(path);
      return true;
    } finally {
      try {
        await staging.delete(recursive: true);
      } on Object catch (error) {
        _logExportError('export.staging_cleanup.error', error);
      }
    }
  }
}
