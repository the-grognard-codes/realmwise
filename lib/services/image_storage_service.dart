import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/catalog_models.dart';

/// Optional test seam. The resolved peer is supplied by the service, so an
/// injected transport cannot perform an independent DNS lookup.
typedef ImageSecureTransport =
    Future<http.StreamedResponse> Function(Uri uri, InternetAddress peer);
typedef ImageSocketConnector =
    Future<ConnectionTask<Socket>> Function(InternetAddress peer, int port);
typedef ImageTlsUpgrader =
    Future<Socket> Function(Socket socket, {required String host});

/// Opens a pinned TCP connection and upgrades it to TLS using the original
/// hostname for SNI and certificate validation.
@visibleForTesting
Future<ConnectionTask<Socket>> imagePinnedTlsConnection(
  Uri uri,
  InternetAddress peer, {
  required int port,
  ImageSocketConnector? connector,
  ImageTlsUpgrader? upgrader,
}) {
  final tcpTask = (connector ?? Socket.startConnect)(peer, port);
  final tlsUpgrade =
      upgrader ??
      (Socket socket, {required String host}) =>
          SecureSocket.secure(socket, host: host);
  return tcpTask.then(
    (task) => ConnectionTask.fromSocket<Socket>(
      task.socket.then((socket) => tlsUpgrade(socket, host: uri.host)),
      task.cancel,
    ),
  );
}

class _DownloadedImage {
  _DownloadedImage(this.bodyBytes, this.headers);
  final Uint8List bodyBytes;
  final Map<String, String> headers;
}

enum _ImageFormat { jpeg, png, gif, bmp, webp }

/// Keeps work imagery in a portable local folder and never relies on a URL at display time.
class ImageStorageService {
  ImageStorageService(
    http.Client? legacyClient, {
    Future<List<InternetAddress>> Function(String host)? resolver,
    this._transport,
  }) : _resolver = resolver ?? ((host) => InternetAddress.lookup(host));
  final Future<List<InternetAddress>> Function(String host) _resolver;
  final ImageSecureTransport? _transport;
  static const _maxRemoteBytes = 10 * 1024 * 1024;
  static const _maxRedirects = 5;
  String? _rootPath;

  String get rootPath =>
      _rootPath ??
      (throw StateError('Image storage has not been initialized.'));

  Future<String> initialize(String? configuredPath) async {
    final defaultDirectory = await getApplicationDocumentsDirectory();
    final chosen = configuredPath?.trim().isNotEmpty == true
        ? configuredPath!.trim()
        : await _defaultDirectory(defaultDirectory.path);
    await Directory(chosen).create(recursive: true);
    _rootPath = chosen;
    return chosen;
  }

  Future<String> _defaultDirectory(String documentsPath) async {
    final legacy = Directory(path.join(documentsPath, 'rpg_catalog_images'));
    if (await legacy.exists()) return legacy.path;
    return path.join(documentsPath, 'realmwise_images');
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

  Future<String> importCatalogIcon({
    required String sourcePath,
    required String tier,
    required String sectionName,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists())
      throw FileSystemException(
        'The selected image no longer exists.',
        sourcePath,
      );
    final ext = _extensionFor(sourcePath, fallback: '.png');
    final label = _cleanLabel('${tier}_$sectionName');
    final destination = await _uniquePath(rootPath, 'icon_$label', ext);
    await source.copy(destination.path);
    return destination.path;
  }

  Future<BookImage> downloadRemoteCover({
    required BookWork work,
    required String remoteUrl,
  }) async {
    final uri = Uri.tryParse(remoteUrl.trim());
    try {
      if (uri == null || uri.host.isEmpty || uri.scheme != 'https') {
        throw ArgumentError.value(
          remoteUrl,
          'remoteUrl',
          'A valid HTTPS image URL is required.',
        );
      }
      final response = await _download(
        uri,
      ).timeout(const Duration(seconds: 12));
      final contentType = response.headers['content-type'];
      final format = _imageFormat(response.bodyBytes);
      final type = contentType?.split(';').first.trim().toLowerCase();
      // The bytes are the authoritative image format. CDNs commonly omit the
      // header, use a generic binary type, or label a valid image with a stale
      // image subtype. Keep rejecting explicit non-image responses while
      // allowing supported image signatures through.
      if (format == null || !_contentTypeAllowsImage(type)) {
        throw HttpException('Image download did not return an image.');
      }
      final extension = _extensionForFormat(format);
      final destination = await _availableFile(
        work: work,
        label: 'remote',
        extension: extension,
        cover: true,
      );
      final partial = File('${destination.path}.part');
      try {
        await partial.writeAsBytes(response.bodyBytes, flush: true);
        await partial.rename(destination.path);
      } catch (_) {
        if (await partial.exists()) await partial.delete();
        rethrow;
      }
      return BookImage(
        localPath: destination.path,
        remoteUrl: remoteUrl,
        caption: 'Remote cover',
        isCover: true,
        sourceType: ImageSourceType.remoteCache,
      );
    } catch (_) {
      rethrow;
    }
  }

  Future<_DownloadedImage> _download(Uri initial) async {
    var uri = initial;
    for (var redirect = 0; redirect <= _maxRedirects; redirect++) {
      final peers = await _validateEndpoint(uri);
      http.StreamedResponse? response;
      for (final peer in peers) {
        try {
          response = await _sendPinned(uri, peer);
          break;
        } catch (_) {}
      }
      if (response == null) {
        throw HttpException('Image download connection failed.');
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location == null)
          throw HttpException('Image download redirect lacked a location.');
        await response.stream.drain();
        uri = uri.resolve(location);
        if (uri.scheme != 'https')
          throw HttpException('Image download redirects must use HTTPS.');
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Image download returned HTTP ${response.statusCode}.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > _maxRemoteBytes) {
          throw HttpException('Image download exceeds the size limit.');
        }
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty)
        throw HttpException('Image download returned an empty body.');
      return _DownloadedImage(Uint8List.fromList(bytes), response.headers);
    }
    throw HttpException('Image download exceeded the redirect limit.');
  }

  Future<List<InternetAddress>> _validateEndpoint(Uri uri) async {
    if (uri.scheme != 'https' || uri.host.isEmpty)
      throw HttpException('Image download URL must use HTTPS.');
    List<InternetAddress> addresses;
    try {
      addresses = await _resolver(uri.host);
    } catch (_) {
      throw HttpException('Image download host could not be resolved.');
    }
    final peers = addresses
        .where((address) => !_isBlockedAddress(address))
        .toList();
    if (peers.isEmpty) {
      throw HttpException(
        'Image download host resolves to a restricted address.',
      );
    }
    return peers;
  }

  Future<http.StreamedResponse> _sendPinned(
    Uri uri,
    InternetAddress peer,
  ) async {
    if (_transport != null) return _transport(uri, peer);
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (requestUri, host, port) =>
          imagePinnedTlsConnection(
            requestUri,
            peer,
            port: port ?? requestUri.port,
          );
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'image/*');
      final response = await request.close();
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.join(', ');
      });
      final body = StreamController<List<int>>(sync: true);
      late StreamSubscription<List<int>> subscription;
      body.onListen = () {
        subscription = response.listen(
          body.add,
          onError: (Object error, StackTrace stack) {
            client.close(force: true);
            body.addError(error, stack);
            body.close();
          },
          onDone: () {
            client.close();
            body.close();
          },
          cancelOnError: false,
        );
      };
      body.onCancel = () async {
        client.close(force: true);
        await subscription.cancel();
      };
      return http.StreamedResponse(
        body.stream,
        response.statusCode,
        contentLength: response.contentLength,
        request: http.Request('GET', uri),
        headers: headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  bool _isBlockedAddress(InternetAddress address) {
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && raw.length == 4) {
      final a = raw[0], b = raw[1];
      return a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 192 && (b == 0 || b == 2)) ||
          (a == 198 && (b == 18 || b == 19 || b == 51)) ||
          (a == 203 && b == 0) ||
          (a == 100 && b >= 64 && b <= 127) ||
          a >= 224;
    }
    if (raw.length != 16) return true;
    final isV4Mapped =
        raw.sublist(0, 10).every((v) => v == 0) &&
        raw[10] == 255 &&
        raw[11] == 255;
    if (isV4Mapped)
      return _isBlockedAddress(InternetAddress.fromRawAddress(raw.sublist(12)));
    return raw.every((v) => v == 0) ||
        (raw.sublist(0, 15).every((v) => v == 0) && raw[15] == 1) ||
        (raw[0] & 0xfe) == 0xfc ||
        (raw[0] & 0xfe) == 0xfe && (raw[1] & 0xc0) == 0x80 ||
        raw[0] == 0xff;
  }

  _ImageFormat? _imageFormat(Uint8List b) {
    bool starts(List<int> p) =>
        b.length >= p.length &&
        p.asMap().entries.every((e) => b[e.key] == e.value);
    if (starts([0xff, 0xd8, 0xff])) return _ImageFormat.jpeg;
    if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
      return _ImageFormat.png;
    if (starts([0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
        starts([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]))
      return _ImageFormat.gif;
    if (starts([0x42, 0x4d])) return _ImageFormat.bmp;
    if (starts([0x52, 0x49, 0x46, 0x46]) &&
        b.length >= 12 &&
        String.fromCharCodes(b.sublist(8, 12)) == 'WEBP')
      return _ImageFormat.webp;
    return null;
  }

  bool _contentTypeAllowsImage(String? type) {
    if (type == null || type.isEmpty) return true;
    if (type.startsWith('image/')) return true;
    return type == 'application/octet-stream' ||
        type == 'binary/octet-stream' ||
        type == 'application/x-download';
  }

  String _extensionForFormat(_ImageFormat format) {
    return switch (format) {
      _ImageFormat.jpeg => '.jpg',
      _ImageFormat.png => '.png',
      _ImageFormat.gif => '.gif',
      _ImageFormat.bmp => '.bmp',
      _ImageFormat.webp => '.webp',
    };
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
    final cropped = normalized.length > 32
        ? normalized.substring(0, 32)
        : normalized;
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
}
