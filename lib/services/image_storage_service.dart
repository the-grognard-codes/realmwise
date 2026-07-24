import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/catalog_models.dart';

/// Keeps work imagery in a portable local folder and never relies on a URL at display time.
class ImageStorageService {
  ImageStorageService(this._client);
  final http.Client _client;
  String? _rootPath;

  String get rootPath =>
      _rootPath ??
      (throw StateError('Image storage has not been initialized.'));

  Future<String> initialize(String? configuredPath) async {
    final defaultDirectory = await getApplicationDocumentsDirectory();
    final chosen = configuredPath?.trim().isNotEmpty == true
        ? configuredPath!.trim()
        : path.join(defaultDirectory.path, 'rpg_catalog_images');
    await Directory(chosen).create(recursive: true);
    _rootPath = chosen;
    return chosen;
  }

  Future<BookImage> importFile({
    required BookWork work,
    required String sourcePath,
    required String label,
    required bool cover,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists())
      throw FileSystemException(
        'The selected image no longer exists.',
        sourcePath,
      );
    final extension = _extensionFor(sourcePath, fallback: '.jpg');
    final destination = await _availableFile(
      work: work,
      label: label,
      extension: extension,
      cover: cover,
    );
    await source.copy(destination.path);
    return BookImage(
      localPath: destination.path,
      caption: _cleanLabel(label),
      isCover: cover,
    );
  }

  Future<String> importCatalogIcon({required String sourcePath, required String tier, required String sectionName}) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw FileSystemException('The selected image no longer exists.', sourcePath);
    final ext = _extensionFor(sourcePath, fallback: '.png');
    final label = _cleanLabel('${tier}_${sectionName}');
    final destination = await _uniquePath(rootPath, 'icon_$label', ext);
    await source.copy(destination.path);
    return destination.path;
  }

  Future<BookImage> downloadRemoteCover({
    required BookWork work,
    required String remoteUrl,
  }) async {
    final response = await _client
        .get(Uri.parse(remoteUrl))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        response.bodyBytes.isEmpty) {
      throw HttpException(
        'Image download returned HTTP ${response.statusCode}.',
      );
    }
    final extension = _extensionFromResponse(
      remoteUrl,
      response.headers['content-type'],
    );
    final destination = await _availableFile(
      work: work,
      label: 'remote',
      extension: extension,
      cover: true,
    );
    await destination.writeAsBytes(response.bodyBytes, flush: true);
    return BookImage(
      localPath: destination.path,
      remoteUrl: remoteUrl,
      caption: 'Remote cover',
      isCover: true,
    );
  }

  Future<BookImage> setCover(BookImage image, bool cover) async {
    final existing = File(image.localPath);
    if (!await existing.exists()) return image.copyWith(isCover: cover);
    final extension = path.extension(existing.path);
    final stem = path
        .basenameWithoutExtension(existing.path)
        .replaceFirst(RegExp(r'_cover$'), '');
    final desired = path.join(
      path.dirname(existing.path),
      '$stem${cover ? '_cover' : ''}$extension',
    );
    if (path.normalize(desired) == path.normalize(existing.path))
      return image.copyWith(isCover: cover);
    var target = File(desired);
    if (await target.exists()) {
      target = await _uniquePath(
        path.dirname(existing.path),
        path.basenameWithoutExtension(desired),
        extension,
      );
    }
    final renamed = await existing.rename(target.path);
    return image.copyWith(localPath: renamed.path, isCover: cover);
  }

  Future<void> deleteImage(BookImage image) async {
    final file = File(image.localPath);
    if (await file.exists()) await file.delete();
  }

  Future<File> _availableFile({
    required BookWork work,
    required String label,
    required String extension,
    required bool cover,
  }) async {
    final identifier =
        work.isbn13.replaceAll(RegExp(r'[^0-9Xx]'), '').isNotEmpty
            ? work.isbn13.replaceAll(RegExp(r'[^0-9Xx]'), '')
            : 'work_${work.id ?? DateTime.now().millisecondsSinceEpoch}';
    final name = '${identifier}_${_cleanLabel(label)}${cover ? '_cover' : ''}';
    return _uniquePath(rootPath, name, extension);
  }

  Future<File> _uniquePath(
    String directory,
    String baseName,
    String extension,
  ) async {
    var candidate = File(path.join(directory, '$baseName$extension'));
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = File(path.join(directory, '${baseName}_$suffix$extension'));
      suffix++;
    }
    return candidate;
  }

  String _cleanLabel(String value) {
    final normalized = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final cropped =
        normalized.length > 32 ? normalized.substring(0, 32) : normalized;
    return cropped.isEmpty ? 'image' : cropped;
  }

  String _extensionFor(String filePath, {required String fallback}) {
    final extension = path.extension(filePath).toLowerCase();
    return const [
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.gif',
      '.bmp',
    ].contains(extension)
        ? extension
        : fallback;
  }

  String _extensionFromResponse(String url, String? contentType) {
    final fromUrl = _extensionFor(Uri.tryParse(url)?.path ?? '', fallback: '');
    if (fromUrl.isNotEmpty) return fromUrl;
    final type = (contentType ?? '').toLowerCase();
    if (type.contains('png')) return '.png';
    if (type.contains('webp')) return '.webp';
    if (type.contains('gif')) return '.gif';
    return '.jpg';
  }
}
