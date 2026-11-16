import 'dart:io';

import 'package:file_selector/file_selector.dart' as selector;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'diagnostic_bundle_exporter.dart';

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
    } on Object {
      // Plugin and producer errors can contain credentials or private paths.
      result = const ExportFailed();
    }
    if (target != null && result is! ExportSaved) {
      try {
        await target.discard();
      } on Object {
        // Preserve the safe original result if destination cleanup fails.
      }
    }
    if (staging != null) {
      try {
        await staging.delete(recursive: true);
      } on Object {
        return const ExportFailed();
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

class DesktopExportDestinationAdapter implements ExportDestinationAdapter {
  const DesktopExportDestinationAdapter({ExportSaveDialog? saveDialog})
    : _saveDialog = saveDialog ?? _showSaveDialog;

  final ExportSaveDialog _saveDialog;

  static Future<String?> _showSaveDialog({required String fileName}) async {
    final location = await selector.getSaveLocation(suggestedName: fileName);
    return location?.path;
  }

  @override
  Future<ExportTarget?> chooseDestination({
    required String fileName,
    required String mimeType,
  }) async {
    final path = await _saveDialog(fileName: fileName);
    return path == null ? null : _DesktopTarget(path);
  }
}

class _DesktopTarget extends ExportTarget {
  _DesktopTarget(this.path);
  final String path;
  @override
  String get locationDescription => p.basename(path);

  @override
  Future<bool> save(String temporaryPath) async {
    await File(temporaryPath).copy(path);
    return true;
  }
}
